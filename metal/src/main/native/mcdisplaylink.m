// Experimental CAMetalDisplayLink pacing. No extra rendering thread or staging queue: the game
// pumps only this private run-loop mode before polling SDL input, then renders using that update.
// Never call nextDrawable while the link is active. Missing callbacks have a bounded wait so
// hidden windows, sleep and display changes cannot trap the game/event loop.
#import "mcdisplaylink.h"
#import <QuartzCore/CAMetalDisplayLink.h>
#import <QuartzCore/CATransaction.h>
#import <AppKit/AppKit.h>
#include <math.h>
#import "mcpresentationtrace.h"

static NSString *const MCDisplayMode = @"mcopt.display-link";
// Lifecycle and renderer fences share the render thread. Track registrations rather than
// the user's enabled preference: a retiring link still needs its owning run loop.
static _Thread_local unsigned int registeredLinks;

static void serviceDisplayLoop(void) {
    @autoreleasepool {
        // Do not dispatch SDL input or re-enter the game while it is retiring resources.
        // Delegate calls outside begin() discard updates instead of acquiring more frames.
        SInt32 result = CFRunLoopRunInMode((CFStringRef)MCDisplayMode, 0.001, true);
        if (result == kCFRunLoopRunFinished) [NSThread sleepForTimeInterval:0.001];
    }
}

void mc_display_link_wait_for_command(id<MTLCommandBuffer> commandBuffer) {
    if (commandBuffer && registeredLinks && commandBuffer.status < MTLCommandBufferStatusCompleted) {
        mc_presentation_mark("link.gpu-wait.begin", commandBuffer, commandBuffer.status);
        double nextReport = CACurrentMediaTime() + 1;
        while (commandBuffer.status < MTLCommandBufferStatusCompleted) {
            serviceDisplayLoop();
            double now = CACurrentMediaTime();
            if (now >= nextReport) {
                // Callbacks can keep the CPU breadcrumb monitor alive even when the GPU
                // isn't progressing. Persist the outstanding command explicitly as well.
                mc_presentation_mark("link.gpu-wait.pending", commandBuffer, commandBuffer.status);
                mc_presentation_snapshot("GPU fence pending while servicing display callbacks");
                nextReport = now + 5;
            }
        }
        mc_presentation_mark("link.gpu-wait.end", commandBuffer, commandBuffer.status);
    }
    // Preserve waitUntilCompleted's completion-handler ordering before Java recycles
    // resources. With a link registered, the GPU has already reached a terminal status.
    [commandBuffer waitUntilCompleted];
}

@interface MCDisplayStats : NSObject {
@public
    unsigned long samples, unavailable, deadlines, timeouts, intervals, gpuErrors;
    unsigned long histogram[256]; // half-millisecond bins, last bin = >=127.5 ms
    double lastPresented, intervalSum, latencySum, lastReport;
}
@end
@implementation MCDisplayStats
@end

@interface MCDisplayFrame : NSObject {
@public
    id<CAMetalDrawable> drawable;
    id<MTLCommandBuffer> commandBuffer;
    MCDisplayStats *stats;
    double began, deadline;
    BOOL presented;
}
@end
@implementation MCDisplayFrame
- (void)dealloc { [commandBuffer release]; [drawable release]; [stats release]; [super dealloc]; }
@end

@interface MCDisplayLink : NSObject <CAMetalDisplayLinkDelegate> {
@public
    CAMetalDisplayLink *link;
    CAMetalLayer *layer;
    NSRunLoop *runLoop;
    MCDisplayFrame *frame;
    MCDisplayStats *stats;
    NSMutableArray<MCDisplayFrame *> *inFlight;
    int requestedRate, logging;
    double nextPresentation;
    BOOL waiting, retiring;
}
@end
@implementation MCDisplayLink
- (void)metalDisplayLink:(CAMetalDisplayLink *)sender needsUpdate:(CAMetalDisplayLinkUpdate *)update {
    mc_presentation_mark("link.callback", self, waiting);
    if (!waiting || frame || !update.drawable) return;
    // Some displays round a 90 Hz request up to 120. Preserve the user's average cap
    // by selecting updates on a deadline grid, without a second sleep after rendering.
    double t = update.targetPresentationTimestamp, period = 1.0 / MAX(1, requestedRate);
    if (nextPresentation > 0 && t + 0.0001 < nextPresentation) return;
    nextPresentation = nextPresentation == 0 || t - nextPresentation > period ? t + period : nextPresentation + period;
    frame = [MCDisplayFrame new];
    frame->drawable = [update.drawable retain];
    frame->stats = [stats retain];
    frame->began = CACurrentMediaTime();
    frame->deadline = update.targetTimestamp;
    CFRunLoopStop(runLoop.getCFRunLoop);
}
- (void)dealloc {
    [link invalidate];
    [link release];
    [frame release];
    [inFlight release];
    [layer release];
    [runLoop release];
    [stats release];
    [super dealloc];
}
@end

// AppKit is consulted only on the main thread, as is mc_layer_display. The SDL game/render
// thread is the main thread on macOS. If hosted elsewhere, let the display link pick its range.
static int maximumRate(CAMetalLayer *layer) {
    if (![NSThread isMainThread]) return 0;
    for (CALayer *l = layer; l; l = l.superlayer) {
        id d = l.delegate;
        if ([d isKindOfClass:[NSView class]]) {
            NSScreen *screen = ((NSView *)d).window.screen;
            if (screen) return (int)screen.maximumFramesPerSecond;
        }
    }
    return 0;
}

void *mc_display_link_create(CAMetalLayer *layer, int latency, int log) {
    if (@available(macOS 14.0, *)) { @autoreleasepool {
        mc_presentation_trace_note("link.create.begin");
        if (mc_presentation_trace_enabled()) {
            NSWindow *window = nil;
            if ([NSThread isMainThread]) for (CALayer *l = layer; l; l = l.superlayer) {
                if ([l.delegate isKindOfClass:[NSView class]]) { window = ((NSView *)l.delegate).window; break; }
            }
            mc_presentation_checkpoint([NSString stringWithFormat:@"link.context layer=%p size=%.0fx%.0f format=%lu sync=%d drawables=%lu edr=%d main=%d screen=%@ maxHz=%ld fullscreenStyle=%d windowFrame=%@ screenFrame=%@",
                layer, layer.drawableSize.width, layer.drawableSize.height, (unsigned long)layer.pixelFormat,
                layer.displaySyncEnabled, (unsigned long)layer.maximumDrawableCount, layer.wantsExtendedDynamicRangeContent,
                [NSThread isMainThread], window.screen.deviceDescription[@"NSScreenNumber"], (long)window.screen.maximumFramesPerSecond,
                (window.styleMask & NSWindowStyleMaskFullScreen) != 0, NSStringFromRect(window.frame), NSStringFromRect(window.screen.frame)]);
        }
        MCDisplayLink *p = [MCDisplayLink new];
        p->layer = [layer retain];
        p->runLoop = [[NSRunLoop currentRunLoop] retain];
        // Core Animation's common-mode observers must run too, to flush layer transactions.
        // SDL input is still polled immediately after this wait returns.
        CFRunLoopAddCommonMode(p->runLoop.getCFRunLoop, (CFStringRef)MCDisplayMode);
        p->stats = [MCDisplayStats new];
        p->inFlight = [NSMutableArray new];
        p->stats->lastReport = CACurrentMediaTime();
        p->logging = log;
        mc_presentation_trace_note("link.init.begin");
        p->link = [[CAMetalDisplayLink alloc] initWithMetalLayer:layer];
        mc_presentation_trace_note("link.init.end");
        if (!p->link) { [p release]; return NULL; }
        p->link.delegate = p;
        p->link.preferredFrameLatency = latency == 2 ? 2 : 1;
        mc_presentation_mark("link.pause.begin", p, 0);
        p->link.paused = YES;
        mc_presentation_mark("link.pause.end", p, 0);
        mc_presentation_trace_note("link.add-runloop.begin");
        [p->link addToRunLoop:p->runLoop forMode:MCDisplayMode];
        registeredLinks++;
        mc_presentation_trace_note("link.create.end");
        NSLog(@"[mcopt] CAMetalDisplayLink enabled (latency %d); VSync off uses legacy pacing", latency == 2 ? 2 : 1);
        return p;
    } }
    return NULL;
}

void mc_display_link_pause(void *handle) {
    MCDisplayLink *p = handle;
    if (!p) return;
    p->waiting = NO;
    p->nextPresentation = 0;
    mc_presentation_mark("link.pause.begin", p, 0);
    p->link.paused = YES;
    mc_presentation_mark("link.pause.end", p, 0);
    [p->frame release];
    p->frame = nil;
    @synchronized(p->stats) { p->stats->lastPresented = 0; }
}

// Only the render thread touches this list. Status is polled, never waited on: a delayed
// GPU must not block input or make us invalidate the drawable's owner prematurely.
static void retireFrames(MCDisplayLink *p) {
    for (NSInteger i = (NSInteger)p->inFlight.count - 1; i >= 0; i--) {
        MCDisplayFrame *f = p->inFlight[i];
        if (f->presented && f->commandBuffer && f->commandBuffer.status >= MTLCommandBufferStatusCompleted)
            [p->inFlight removeObjectAtIndex:i];
    }
}

int mc_display_link_close(void *handle) {
    MCDisplayLink *p = handle;
    if (!p) return 1;
    if (!p->retiring) mc_presentation_snapshot("link.close: recent CPU stages");
    if (!p->retiring && mc_presentation_trace_enabled()) mc_presentation_checkpoint([NSString stringWithFormat:@"link.close.begin handle=%p inFlight=%lu acquired=%d", p, (unsigned long)p->inFlight.count, p->frame != nil]);
    mc_presentation_mark("link.close.poll", p, p->inFlight.count);
    p->waiting = NO;
    // This drawable was acquired but never encoded. Frames handed to an encoder are
    // held separately, including the interval before that encoder commits them.
    [p->frame release];
    p->frame = nil;
    retireFrames(p);
    if (p->inFlight.count) {
        // Retirement must keep servicing the same mode as begin(). Merely polling
        // command status strands display transactions when native fullscreen needs
        // callbacks to advance. Keep each close attempt bounded.
        serviceDisplayLoop();
        retireFrames(p);
    }
    if (p->inFlight.count) {
        if (!p->retiring && p->logging) NSLog(@"[mcopt] display link: switching, waiting for %lu GPU frame(s)", (unsigned long)p->inFlight.count);
        if (!p->retiring) mc_presentation_trace_note("link.close.deferred: encoded/submitted frames remain");
        p->retiring = YES;
        return 0; // caller keeps ownership, skips presentation and retries next frame
    }
    mc_presentation_trace_note("link.close.gpu-retired");
    mc_display_link_pause(p);
    p->link.delegate = nil;
    // invalidate already removes all run-loop registrations. Do it exactly once and
    // only after every encoded drawable has been submitted, presented and completed.
    mc_presentation_trace_note("link.invalidate.begin");
    [p->link invalidate];
    mc_presentation_trace_note("link.invalidate.end");
    [p->link release];
    p->link = nil; // invalidate exactly once; repeated invalidation crashes on macOS 27
    registeredLinks--;
    mc_presentation_trace_note("link.transaction-flush.begin");
    [CATransaction flush];
    mc_presentation_trace_note("link.transaction-flush.end");
    if (p->logging) NSLog(@"[mcopt] display link: stopped after GPU frames completed");
    [p release];
    mc_presentation_trace_note("link.close.end");
    return 1;
}

static void report(MCDisplayLink *p) {
    if (!p->logging) return;
    MCDisplayStats *s = p->stats;
    double now = CACurrentMediaTime();
    @synchronized(s) {
        if (now - s->lastReport < 10) return;
        unsigned long n = 0, goal = (s->intervals * 95 + 99) / 100;
        double p95 = 0;
        for (int i = 0; i < 256 && n < goal; i++) { n += s->histogram[i]; p95 = (i + 1) * 0.5; }
        NSLog(@"[mcopt] display link: request %d Hz, shown %lu, interval avg/p95 %.2f/%.2f ms, callback-to-display %.2f ms, late commits %lu, no drawable %lu, no timestamp %lu, GPU errors %lu",
            p->requestedRate, s->samples, s->intervals ? s->intervalSum * 1000 / s->intervals : 0, p95,
            s->samples ? s->latencySum * 1000 / s->samples : 0, s->deadlines, s->timeouts, s->unavailable, s->gpuErrors);
        s->samples = s->intervals = s->deadlines = s->timeouts = s->unavailable = s->gpuErrors = 0;
        s->intervalSum = s->latencySum = 0;
        memset(s->histogram, 0, sizeof(s->histogram));
        s->lastReport = now;
    }
}

int mc_display_link_begin(void *handle, int cap) {
    MCDisplayLink *p = handle;
    if (!p || p->retiring) return 0;
    @autoreleasepool {
        retireFrames(p);
        [p->frame release]; // a frame that didn't draw (e.g. reconfiguration/loading)
        p->frame = nil;
        int maximum = maximumRate(p->layer);
        int rate = MAX(30, MIN(cap, maximum > 0 ? maximum : cap));
        if (p->requestedRate != rate) {
            // Request a steady sustainable cap. This is a preference, not a physical VRR lock:
            // macOS can still choose a lower rate for power/thermal/display constraints.
            p->link.preferredFrameRateRange = CAFrameRateRangeMake(rate, rate, rate);
            p->requestedRate = rate;
            p->nextPresentation = 0;
            if (p->logging) NSLog(@"[mcopt] display link: requested %d Hz (cap %d, screen maximum %d)", rate, cap, maximum);
        }
        mc_presentation_mark("link.resume.begin", p, rate);
        p->link.paused = NO;
        mc_presentation_mark("link.wait.begin", p, rate);
        p->waiting = YES;
        double stop = CACurrentMediaTime() + 0.050;
        while (!p->frame && CACurrentMediaTime() < stop) {
            CFRunLoopRunInMode((CFStringRef)MCDisplayMode, fmax(0, stop - CACurrentMediaTime()), true);
        }
        p->waiting = NO;
        mc_presentation_mark("link.wait.end", p, p->frame != nil);
        if (!p->frame) { @synchronized(p->stats) { p->stats->timeouts++; } }
        report(p);
        return p->frame != nil;
    }
}

id<CAMetalDrawable> mc_display_link_drawable(void *handle) {
    MCDisplayLink *p = handle;
    return p && p->frame ? p->frame->drawable : nil;
}
id mc_display_link_take(void *handle) {
    MCDisplayLink *p = handle;
    MCDisplayFrame *frame = p->frame;
    p->frame = nil;
    if (frame) [p->inFlight addObject:frame];
    return frame;
}

void mc_display_link_prepare(id object, id<MTLCommandBuffer> cb) {
    MCDisplayFrame *f = object;
    mc_presentation_mark("link.prepare", cb, 0);
    f->commandBuffer = [cb retain];
    MCDisplayStats *s = f->stats; // retained by the copied blocks until GPU/display completes
    double began = f->began;
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        if (done.status == MTLCommandBufferStatusError) { @synchronized(s) { s->gpuErrors++; } }
    }];
    [f->drawable addPresentedHandler:^(id<MTLDrawable> d) {
        double shown = d.presentedTime;
        @synchronized(s) {
            if (!(shown > 0)) { s->unavailable++; return; }
            s->samples++;
            s->latencySum += fmax(0, shown - began);
            if (s->lastPresented > 0 && shown > s->lastPresented) {
                double dt = shown - s->lastPresented;
                s->intervalSum += dt;
                s->intervals++;
                s->histogram[MIN(255, (int)(dt * 2000))]++;
            }
            s->lastPresented = shown;
        }
    }];
}

void mc_display_link_present(id object) {
    MCDisplayFrame *f = object;
    // Apple's display-link deadline is the CPU present deadline, not GPU completion.
    // Commit all rendering first, then call the drawable directly; no scheduled-handler delay.
    if (CACurrentMediaTime() > f->deadline) { @synchronized(f->stats) { f->stats->deadlines++; } }
    mc_presentation_mark("link.present.begin", f->commandBuffer, 0);
    [f->drawable present];
    mc_presentation_mark("link.present.end", f->commandBuffer, 0);
    f->presented = YES;
}
