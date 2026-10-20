// Presentation and queue experiments before SDL input polling. CADisplayLink keeps
// the layer's run loop serviced; only the historical clock policy aligns to its ticks.
// Ordinary VSync drawables retain the existing GPU/layer retirement protections.
#import "mcdisplaylink.h"
#import <QuartzCore/CADisplayLink.h>
#import <QuartzCore/CATransaction.h>
#import <AppKit/AppKit.h>
#include <math.h>
#import "mcpresentationtrace.h"
#include "mcpacing.h"
#include "mcpresentpolicy.h"

static NSString *const MCDisplayMode = @"mcopt.display-link";
void mc_sleep_precise(int64_t ns);
// Lifecycle and renderer fences share the render thread. Track registrations rather than
// the user's enabled preference: a retiring link still needs its owning run loop.
static _Thread_local unsigned int registeredLinks;

static void serviceDisplayLoop(void) {
    @autoreleasepool {
        // Do not dispatch SDL input or re-enter the game while it is retiring resources.
        // Delegate calls only update the clock; they never acquire more frames.
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
    MCPresentFeedback feedback;
}
@end
@implementation MCDisplayStats
@end

@interface MCDisplayFrame : NSObject {
@public
    id<CAMetalDrawable> drawable;
    id<MTLCommandBuffer> commandBuffer;
    MCDisplayStats *stats;
    double began, deadline, inputReady, minimumDuration;
    BOOL presented;
}
@end
@implementation MCDisplayFrame
- (void)dealloc { [commandBuffer release]; [drawable release]; [stats release]; [super dealloc]; }
@end

@interface MCDisplayLink : NSObject {
@public
    CADisplayLink *link;
    CAMetalLayer *layer;
    NSRunLoop *runLoop;
    MCDisplayFrame *frame;
    MCDisplayStats *stats;
    NSMutableArray<MCDisplayFrame *> *inFlight;
    int requestedRate, callbackRate, logging;
    double callbackTarget, callbackInterval, callbackAt;
    MCPacing pacing;
    unsigned long alignedFrames, unalignedFrames;
    int presentationMode, queueLimit;
    double lastInput, queueCooldown, queueWaitSeconds;
    unsigned long queueWaits, queueTimeouts;
    unsigned queueGpuHigh, queueDisplayHigh;
    BOOL waiting, retiring;
}
@end
@implementation MCDisplayLink
- (void)tick:(CADisplayLink *)sender {
    mc_presentation_mark("link.callback", self, waiting);
    double target = sender.targetTimestamp, interval = target - sender.timestamp;
    if (!isfinite(target) || !isfinite(interval) || interval <= 0 || interval > .100) return;
    callbackTarget = target;
    callbackInterval = interval;
    callbackAt = CACurrentMediaTime();
    // Keep the clock current during resource fences too. This callback never
    // acquires a drawable or starts rendering; begin() controls both.
    if (waiting) CFRunLoopStop(runLoop.getCFRunLoop);
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
// thread is the main thread on macOS. Other hosts fall back to ordinary presentation.
static NSView *layerView(CAMetalLayer *layer) {
    if (![NSThread isMainThread]) return nil;
    for (CALayer *l = layer; l; l = l.superlayer)
        if ([l.delegate isKindOfClass:[NSView class]]) return (NSView *)l.delegate;
    return nil;
}
static int maximumRate(CAMetalLayer *layer) {
    return (int)layerView(layer).window.screen.maximumFramesPerSecond;
}

void *mc_display_link_create(CAMetalLayer *layer, int unusedLatency, int log) {
    if (@available(macOS 14.0, *)) { @autoreleasepool {
        mc_presentation_trace_note("link.create.begin");
        NSView *view = layerView(layer);
        if (!view || !view.window) return NULL;
        if (mc_presentation_trace_enabled()) {
            NSWindow *window = nil;
            if ([NSThread isMainThread]) for (CALayer *l = layer; l; l = l.superlayer) {
                if ([l.delegate isKindOfClass:[NSView class]]) { window = ((NSView *)l.delegate).window; break; }
            }
            mc_presentation_checkpoint([NSString stringWithFormat:@"link.context layer=%p size=%.0fx%.0f format=%lu sync=%d drawables=%lu edr=%d main=%d screen=%@ maxHz=%ld minRefreshMs=%.3f maxRefreshMs=%.3f granularityMs=%.3f fullscreenStyle=%d windowFrame=%@ screenFrame=%@",
                layer, layer.drawableSize.width, layer.drawableSize.height, (unsigned long)layer.pixelFormat,
                layer.displaySyncEnabled, (unsigned long)layer.maximumDrawableCount, layer.wantsExtendedDynamicRangeContent,
                [NSThread isMainThread], window.screen.deviceDescription[@"NSScreenNumber"], (long)window.screen.maximumFramesPerSecond,
                window.screen.minimumRefreshInterval * 1000, window.screen.maximumRefreshInterval * 1000,
                window.screen.displayUpdateGranularity * 1000,
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
        p->link = [[view displayLinkWithTarget:p selector:@selector(tick:)] retain];
        mc_presentation_trace_note("link.init.end");
        if (!p->link) { [p release]; return NULL; }
        mc_presentation_mark("link.pause.begin", p, 0);
        p->link.paused = YES;
        mc_presentation_mark("link.pause.end", p, 0);
        mc_presentation_trace_note("link.add-runloop.begin");
        [p->link addToRunLoop:p->runLoop forMode:MCDisplayMode];
        registeredLinks++;
        mc_presentation_trace_note("link.create.end");
        NSLog(@"[mcopt] presentation experiment enabled (VSync, ordinary drawable pool)");
        return p;
    } }
    return NULL;
}

void mc_display_link_pause(void *handle) {
    MCDisplayLink *p = handle;
    if (!p) return;
    p->waiting = NO;
    p->callbackTarget = p->callbackInterval = p->callbackAt = 0;
    mc_pacing_reset(&p->pacing);
    p->lastInput = 0;
    mc_presentation_mark("link.pause.begin", p, 0);
    p->link.paused = YES;
    mc_presentation_mark("link.pause.end", p, 0);
    [p->frame release];
    p->frame = nil;
    @synchronized(p->stats) { p->stats->lastPresented = 0; }
}

void mc_display_link_configure(void *handle, int mode, int queueLimit) {
    MCDisplayLink *p = handle;
    if (!p || p->retiring) return;
    mode = MAX(MC_PRESENT_CLOCK, MIN(MC_PRESENT_PRECISE, mode));
    queueLimit = MAX(0, MIN(3, queueLimit));
    if (p->presentationMode == mode && p->queueLimit == queueLimit) return;
    p->presentationMode = mode;
    p->queueLimit = queueLimit;
    p->lastInput = p->queueCooldown = 0;
    mc_pacing_reset(&p->pacing);
    // Do not reset feedback: callbacks for already submitted frames still own it.
    if (p->logging) NSLog(@"[mcopt] presentation policy=%d queue=%d (0=clock 1=ready 2=duration 3=adaptive 4=precise)", mode, queueLimit);
}

// Only the render thread touches this list. Status is polled, never waited on: a delayed
// GPU must not block input or make us invalidate the drawable's owner prematurely.
static void retireFrames(MCDisplayLink *p) {
    for (NSInteger i = (NSInteger)p->inFlight.count - 1; i >= 0; i--) {
        MCDisplayFrame *f = p->inFlight[i];
        if (f->presented && f->commandBuffer && f->commandBuffer.status >= MTLCommandBufferStatusCompleted) {
            if (f->commandBuffer.status == MTLCommandBufferStatusCompleted && f->inputReady > 0)
                mc_pacing_sample(&p->pacing, f->commandBuffer.GPUEndTime - f->inputReady);
            [p->inFlight removeObjectAtIndex:i];
        }
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
        NSLog(@"[mcopt] display link: request %d Hz, shown %lu, interval avg/p95 %.2f/%.2f ms, start-to-display %.2f ms, commits after estimated finish %lu, no drawable %lu, no timestamp %lu, GPU errors %lu",
            p->requestedRate, s->samples, s->intervals ? s->intervalSum * 1000 / s->intervals : 0, p95,
            s->samples ? s->latencySum * 1000 / s->samples : 0, s->deadlines, s->timeouts, s->unavailable, s->gpuErrors);
        s->samples = s->intervals = s->deadlines = s->timeouts = s->unavailable = s->gpuErrors = 0;
        s->intervalSum = s->latencySum = 0;
        memset(s->histogram, 0, sizeof(s->histogram));
        s->lastReport = now;
    }
    NSLog(@"[mcopt] frame budget: %.2f ms, callback interval %.2f ms, aligned %lu, without extra tick %lu",
        p->pacing.budget * 1000, p->callbackInterval * 1000, p->alignedFrames, p->unalignedFrames);
    p->alignedFrames = p->unalignedFrames = 0;
    NSLog(@"[mcopt] presentation queue: policy=%d limit=%d waits=%lu total=%.2f ms timeouts=%lu GPU/display high=%u/%u",
        p->presentationMode, p->queueLimit, p->queueWaits, p->queueWaitSeconds * 1000,
        p->queueTimeouts, p->queueGpuHigh, p->queueDisplayHigh);
    p->queueWaits = p->queueTimeouts = 0;
    p->queueWaitSeconds = 0;
    p->queueGpuHigh = p->queueDisplayHigh = 0;
}

// Presentation receipts are independent of drawable/resource ownership. Never hold
// drawables alive solely for notification delivery; that can exhaust the drawable pool.
static void waitForQueue(MCDisplayLink *p, int cap) {
    double began = CACurrentMediaTime();
    if (!p->queueLimit || began < p->queueCooldown) return;
    double stop = began + mc_present_wait_limit(cap);
    BOOL waited = NO;
    for (;;) {
        MCPresentBacklog b;
        @synchronized(p->stats) { b = mc_present_backlog(&p->stats->feedback); }
        p->queueGpuHigh = MAX(p->queueGpuHigh, b.gpu);
        p->queueDisplayHigh = MAX(p->queueDisplayHigh, b.display);
        if (b.gpu + b.display < (unsigned)p->queueLimit) break;
        double now = CACurrentMediaTime();
        // Missing/delayed notifications are not a reason to freeze rendering. The
        // normal drawable/GPU fences remain authoritative when this hint backs off.
        if (now >= stop || (b.oldest > 0 && now - b.oldest > .150)) {
            p->queueCooldown = now + 1;
            p->queueTimeouts++;
            break;
        }
        if (!waited) { p->queueWaits++; waited = YES; }
        serviceDisplayLoop();
    }
    if (waited) p->queueWaitSeconds += CACurrentMediaTime() - began;
}

static int beginPresentation(MCDisplayLink *p, int rate) {
    NSWindow *window = layerView(p->layer).window;
    if (!window.visible) return 0;
    CFRunLoopRunInMode((CFStringRef)MCDisplayMode, 0, true);
    // A just-shown window's occlusion state arrives asynchronously. Allow its first
    // transaction to reach AppKit instead of spinning through empty frames at startup.
    if (!p->lastInput) {
        double stop = CACurrentMediaTime() + .050;
        while (!(window.occlusionState & NSWindowOcclusionStateVisible) && CACurrentMediaTime() < stop)
            serviceDisplayLoop();
    }
    if (!(window.occlusionState & NSWindowOcclusionStateVisible)) return 0;
    if (p->presentationMode == MC_PRESENT_READY || p->presentationMode == MC_PRESENT_PRECISE) {
        // A single pre-input cap, without rounding to callback/display intervals.
        double due = p->lastInput > 0 ? p->lastInput + 1.0 / rate : 0;
        while (CACurrentMediaTime() < due) {
            double remaining = fmax(0, due - CACurrentMediaTime());
            if (p->presentationMode == MC_PRESENT_PRECISE) {
                // Isolate timer accuracy from the ready policy's acquisition/deadline
                // behavior. Reuse the legacy limiter's non-coalescable timer. Keep
                // the private run loop progressing at least once per millisecond:
                // display transactions can be needed by outstanding GPU commands.
                mc_sleep_precise((int64_t)ceil(fmin(remaining, .001) * 1e9));
                CFRunLoopRunInMode((CFStringRef)MCDisplayMode, 0, true);
            } else {
                SInt32 result = CFRunLoopRunInMode((CFStringRef)MCDisplayMode, remaining, true);
                if (result == kCFRunLoopRunFinished) [NSThread sleepForTimeInterval:remaining];
            }
        }
    }
    // Duration policies cap presentation itself. No second CPU/callback limiter.
    waitForQueue(p, rate);
    double gpuAverage;
    @synchronized(p->stats) { gpuAverage = p->stats->feedback.gpuAverage; }
    NSScreen *screen = window.screen;
    BOOL eligible = (window.styleMask & NSWindowStyleMaskFullScreen) != 0
        && screen.minimumRefreshInterval > 0
        && screen.maximumRefreshInterval > screen.minimumRefreshInterval;
    p->frame = [MCDisplayFrame new];
    p->frame->stats = [p->stats retain];
    p->frame->began = CACurrentMediaTime();
    p->frame->minimumDuration = mc_present_duration(p->presentationMode, rate, gpuAverage,
        screen.maximumRefreshInterval, eligible);
    mc_presentation_mark("link.acquire.begin", p, 0);
    p->frame->drawable = [[p->layer nextDrawable] retain];
    mc_presentation_mark("link.acquire.end", p, p->frame->drawable != nil);
    if (!p->frame->drawable) { [p->frame release]; p->frame = nil; return 0; }
    p->lastInput = p->frame->inputReady = CACurrentMediaTime();
    return 1;
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
        int callbackRate = maximum > 0 ? maximum : rate;
        if (p->requestedRate != rate || p->callbackRate != callbackRate) {
            p->link.preferredFrameRateRange = CAFrameRateRangeMake(callbackRate, callbackRate, callbackRate);
            p->requestedRate = rate;
            p->callbackRate = callbackRate;
            mc_pacing_reset(&p->pacing);
            p->lastInput = 0;
            p->callbackAt = 0; // require a callback after changing the requested range
            if (p->logging) NSLog(@"[mcopt] display link: cap %d Hz, callbacks requested %d Hz", rate, callbackRate);
        }
        mc_presentation_mark("link.resume.begin", p, rate);
        p->link.paused = NO;
        if (p->presentationMode != MC_PRESENT_CLOCK) {
            int ready = beginPresentation(p, rate);
            if (!ready) { @synchronized(p->stats) { p->stats->timeouts++; } }
            report(p);
            return ready;
        }
        mc_presentation_mark("link.wait.begin", p, rate);
        p->waiting = YES;
        double stop = CACurrentMediaTime() + 0.050;
        // Deliver any pending callback without waiting for an extra display tick.
        CFRunLoopRunInMode((CFStringRef)MCDisplayMode, 0, true);
        while ((p->callbackAt <= 0 || CACurrentMediaTime() - p->callbackAt > .050) && CACurrentMediaTime() < stop) {
            SInt32 result = CFRunLoopRunInMode((CFStringRef)MCDisplayMode, fmax(0, stop - CACurrentMediaTime()), true);
            if (result == kCFRunLoopRunFinished) [NSThread sleepForTimeInterval:.001];
        }
        MCPacingPlan plan = {0};
        if (p->callbackAt > 0 && CACurrentMediaTime() - p->callbackAt <= .050) {
            plan = mc_pacing_plan(&p->pacing, CACurrentMediaTime(), rate, p->callbackTarget, p->callbackInterval);
            double interval = p->callbackInterval;
            // Sleep in the same private run-loop mode used by the lifecycle fixes.
            // No polling SDL input, busy-spin, or unbounded wait for presented callbacks.
            while (CACurrentMediaTime() < fmin(plan.wake, stop)) {
                SInt32 result = CFRunLoopRunInMode((CFStringRef)MCDisplayMode,
                    fmax(0, fmin(plan.wake, stop) - CACurrentMediaTime()), true);
                if (result == kCFRunLoopRunFinished) [NSThread sleepForTimeInterval:.001];
                if (fabs(p->callbackInterval - interval) > interval * .05) {
                    interval = p->callbackInterval;
                    plan = mc_pacing_plan(&p->pacing, CACurrentMediaTime(), rate, p->callbackTarget, interval);
                }
            }
            if (CACurrentMediaTime() >= plan.wake && CACurrentMediaTime() - p->callbackAt <= .050) {
                p->frame = [MCDisplayFrame new];
                p->frame->stats = [p->stats retain];
                p->frame->began = CACurrentMediaTime();
                p->frame->deadline = plan.finish;
            }
        }
        p->waiting = NO;
        if (p->frame) {
            // Acquire before input so drawable backpressure does not age sampled input.
            // This is an ordinary layer drawable, not owned/scheduled by the display link.
            mc_presentation_mark("link.acquire.begin", p, 0);
            p->frame->drawable = [[p->layer nextDrawable] retain];
            mc_presentation_mark("link.acquire.end", p, p->frame->drawable != nil);
            if (!p->frame->drawable) { [p->frame release]; p->frame = nil; }
            else {
                p->frame->inputReady = CACurrentMediaTime();
                mc_pacing_started(&p->pacing, plan, p->frame->inputReady);
                if (plan.clockAligned) p->alignedFrames++; else p->unalignedFrames++;
            }
        }
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
    uint64_t sequence;
    @synchronized(s) { sequence = mc_present_record(&s->feedback, CACurrentMediaTime()); }
    if (f->minimumDuration > 0) [cb presentDrawable:f->drawable afterMinimumDuration:f->minimumDuration];
    else [cb presentDrawable:f->drawable];
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        @synchronized(s) {
            BOOL failed = done.status == MTLCommandBufferStatusError;
            if (failed) s->gpuErrors++;
            mc_present_completed(&s->feedback, sequence, CACurrentMediaTime(), done.GPUEndTime - done.GPUStartTime, failed);
        }
    }];
    [f->drawable addPresentedHandler:^(id<MTLDrawable> d) {
        double shown = d.presentedTime;
        @synchronized(s) {
            if (!(shown > 0)) { s->unavailable++; return; }
            mc_present_shown(&s->feedback, sequence, shown);
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
    // Presentation was scheduled on the command buffer in prepare(). Mark submission
    // separately so a pre-commit disable cannot retire an encoded drawable too early.
    if (f->deadline > 0 && CACurrentMediaTime() > f->deadline) { @synchronized(f->stats) { f->stats->deadlines++; } }
    mc_presentation_mark("link.present.scheduled", f->commandBuffer, 0);
    f->presented = YES;
}
