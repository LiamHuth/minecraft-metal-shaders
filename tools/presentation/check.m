// Live-window test of the production display-link and native present/commit paths.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import "mcmetal.h"
#import "mcdisplaylink.h"
#import "mcpresentationtrace.h"
#include <assert.h>
#include <unistd.h>
static void configurePolicy(void *link) {
    const char *mode = getenv("MCOPT_PRESENT_POLICY"), *queue = getenv("MCOPT_PRESENT_QUEUE");
    mc_display_link_configure(link, mode ? atoi(mode) : 0, queue ? atoi(queue) : 0);
}
@interface ValidationCadence : NSObject {
@public
    double first[3], last[3];
    unsigned shown[3];
}
@end
@implementation ValidationCadence
@end
Ctx *mc_create(char *, int, char *, int);
Enc *mc_enc_new(Ctx *);
void mc_layer_configure(Ctx *, CAMetalLayer *, int, int, int);
void mc_present_display_link(Enc *, void *, id<MTLTexture>, long);
void mc_present(Enc *, id<CAMetalDrawable>, id<MTLTexture>);
id<MTLCommandBuffer> mc_enc_commit(Enc *);
void mc_xdr_enable(int);
void mc_xdr_full_frame(Enc *, id<MTLTexture>, id<MTLTexture>, float, float);
static void events(void) {
    NSEvent *event;
    while ((event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate distantPast] inMode:NSDefaultRunLoopMode dequeue:YES])) [NSApp sendEvent:event];
    [NSApp updateWindows];
}
static void require(BOOL ok, const char *msg) { if (!ok) { fprintf(stderr,"FAIL: %s\n",msg); exit(1); } }
static void closeLink(void *link) {
    double start = CACurrentMediaTime();
    while (!mc_display_link_close(link)) {
        require(CACurrentMediaTime()-start < 2,"retirement finished within two seconds");
        events(); usleep(1000);
    }
}
static void completed(id<MTLCommandBuffer> cb) {
    double start = CACurrentMediaTime();
    while (cb.status < MTLCommandBufferStatusCompleted) {
        require(CACurrentMediaTime()-start < 2,"GPU completion bounded");
        events(); usleep(1000);
    }
    require(cb.status == MTLCommandBufferStatusCompleted,"GPU command completed");
}

// Keep an actual presentation command in flight during a disable request. The previous
// implementation invalidated the display link here. Exercise both pre-commit ownership
// and GPU work delayed by a CPU-signalled event, without blocking the UI thread.
static void transitionCheck(Ctx *ctx, Enc *enc, CAMetalLayer *layer, id<MTLTexture> src) {
    for (int i=0; i<12; i++) { @autoreleasepool {
        void *link = mc_display_link_create(layer,1,0);
        configurePolicy(link);
        require(link && mc_display_link_begin(link,120),"transition acquired drawable");
        id<MTLSharedEvent> gate = [ctx->device newSharedEvent];
        id<MTLCommandBuffer> cb = mc_frame_cmd(enc);
        [cb encodeWaitForEvent:gate value:1];
        mc_present_display_link(enc,link,src,-1);
        double start = CACurrentMediaTime();
        require(!mc_display_link_close(link),"cannot invalidate an encoded, uncommitted frame");
        require(CACurrentMediaTime()-start < .050,"uncommitted retirement is nonblocking");
        require(!mc_display_link_begin(link,120),"retiring link cannot acquire more drawables");
        id<MTLCommandBuffer> done = mc_enc_commit(enc);
        start = CACurrentMediaTime();
        require(!mc_display_link_close(link),"cannot invalidate while GPU holds the drawable");
        require(CACurrentMediaTime()-start < .050,"GPU retirement is nonblocking");
        // Pump events while the deliberately delayed frame still belongs to the link.
        events();
        gate.signaledValue = 1;
        closeLink(link);
        completed(done); [done release]; [gate release];
        // Verify the same layer can return to normal presentation and then start again.
        id<CAMetalDrawable> drawable = [layer nextDrawable];
        require(drawable != nil,"legacy acquisition after retirement");
        mc_present(enc,drawable,src);
        done = mc_enc_commit(enc); completed(done); [done release];
    } }
    void *link = mc_display_link_create(layer,1,0);
    configurePolicy(link);
    require(link && mc_display_link_begin(link,120),"acquired unused drawable");
    require(mc_display_link_close(link),"unused drawable can be discarded without GPU work");
    puts("PASS: 12 delayed-GPU and uncommitted transitions, legacy restart, unused drawable");
}

// Model a completion that depends on the display link's private run loop. The old
// MAX_IN_FLIGHT wait blocked that loop, including after close had deferred teardown.
// A separate watchdog releases the synthetic GPU gate if the regression returns,
// so this test fails instead of leaving a deliberately blocked command on the GPU.
static void runLoopFenceCheck(Ctx *ctx, Enc *enc, CAMetalLayer *layer, id<MTLTexture> src) {
    for (int phase = 0; phase < 3; phase++) { @autoreleasepool {
        void *link = mc_display_link_create(layer,1,0);
        configurePolicy(link);
        require(link && mc_display_link_begin(link,120),"run-loop fence acquired drawable");
        id<MTLSharedEvent> gate = [ctx->device newSharedEvent];
        [mc_frame_cmd(enc) encodeWaitForEvent:gate value:1];
        mc_present_display_link(enc,link,src,-1);
        if (phase != 0) require(!mc_display_link_close(link),"retire before submitting fenced frame");
        id<MTLCommandBuffer> done = mc_enc_commit(enc);
        __block BOOL serviced = NO;
        CFRunLoopPerformBlock(CFRunLoopGetCurrent(), CFSTR("mcopt.display-link"), ^{
            serviced = YES;
            gate.signaledValue = 1;
        });
        CFRunLoopWakeUp(CFRunLoopGetCurrent());
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
            dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE,0), ^{ gate.signaledValue = 1; });
        if (phase == 2) {
            // No events() or begin(): close itself must service its registered mode.
            double stop = CACurrentMediaTime() + 2;
            while (!mc_display_link_close(link)) {
                require(CACurrentMediaTime() < stop,"run-loop retirement bounded");
                usleep(1000);
            }
        } else {
            mc_cmd_wait(done); // actual renderer frame-limit/resource/shutdown fence
            require(serviced,"renderer GPU wait serviced the display run loop");
            closeLink(link);
        }
        require(serviced,"GPU fence/retirement serviced the display run loop");
        require(done.status == MTLCommandBufferStatusCompleted,"run-loop fenced GPU frame completed");
        [done release]; [gate release];
    } }
    puts("PASS: run-loop-dependent GPU completion while active, retiring, and polling close");
}
int main(int argc, const char **argv) { @autoreleasepool {
    const char *trace = getenv("MCOPT_PRESENTATION_TRACE");
    if (trace) require(mc_presentation_trace_open(trace) == 0,"trace opened");
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [NSApp finishLaunching];
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100,100,480,300) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    window.title = @"Metal Shaders — pacing test";
    window.releasedWhenClosed = NO;
    NSView *view = window.contentView;
    view.wantsLayer = YES;
    CAMetalLayer *layer = [CAMetalLayer layer];
    view.layer = layer;
    char name[256], error[1024];
    Ctx *ctx = mc_create(name,sizeof(name),error,sizeof(error));
    require(ctx != NULL,error);
    Enc *enc = mc_enc_new(ctx);
    [window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES]; events();
    for (int mode = 0; mode < 2; mode++) {
        ValidationCadence *cadence = [ValidationCadence new];
        BOOL presentationLimited = getenv("MCOPT_PRESENT_POLICY") && atoi(getenv("MCOPT_PRESENT_POLICY")) >= 2;
        mc_xdr_enable(mode);
        mc_layer_configure(ctx,layer,480,300,1);
        layer.framebufferOnly = NO; // read back the actual presented drawable to verify colour
        void *link = mc_display_link_create(layer,argc > 1 ? atoi(argv[1]) : 1,1);
        configurePolicy(link);
        require(link != NULL,"create display link");
        require(layer.displaySyncEnabled && layer.maximumDrawableCount == 3,"paced VSync preserves drawable count");
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:480 height:300 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        id<MTLTexture> src = [ctx->device newTextureWithDescriptor:td];
        td.pixelFormat = MTLPixelFormatRGBA16Float;
        id<MTLTexture> hdr = [ctx->device newTextureWithDescriptor:td];
        NSUInteger row = 480*(mode ? 8:4);
        id<MTLBuffer> readback = [ctx->device newBufferWithLength:row*300 options:MTLResourceStorageModeShared];
        int callbacks = 0;
        double start = CACurrentMediaTime(), phaseStart = start;
        for (int i=0; i<1560; i++) { @autoreleasepool {
            events();
            if (i==1320 || i==1440) {
                int frames = i==1320 ? 1320 : 120;
                int request = i==1320 ? 120 : 60;
                int ceiling = MIN(request,(int)window.screen.maximumFramesPerSecond);
                if (!presentationLimited) require(CACurrentMediaTime()-phaseStart >= frames/(double)ceiling*.97,"120/60 FPS average cap respected");
                phaseStart=CACurrentMediaTime();
            }
            int cap = i < 1320 ? 120 : i < 1440 ? 60 : 90;
            double wait = CACurrentMediaTime();
            int ready = mc_display_link_begin(link,cap);
            require(CACurrentMediaTime()-wait < 0.150,"bounded callback wait");
            if (!ready) continue;
            callbacks++;
            id<CAMetalDrawable> drawable = mc_display_link_drawable(link);
            require(drawable != nil,"update contains drawable");
            int phase = cap == 120 ? 0 : cap == 60 ? 1 : 2;
            [drawable addPresentedHandler:^(id<MTLDrawable> d) {
                @synchronized(cadence) {
                    double at = d.presentedTime;
                    if (at > cadence->last[phase]) {
                        if (!cadence->first[phase]) cadence->first[phase] = at;
                        cadence->last[phase] = at;
                        cadence->shown[phase]++;
                    }
                }
            }];
            id<MTLCommandBuffer> cb = mc_frame_cmd(enc);
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = src;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(0.25,0.50,0.75,mode?0:1);
            [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
            if (mode) {
                rp.colorAttachments[0].texture = hdr;
                rp.colorAttachments[0].clearColor = MTLClearColorMake(2,2,2,1);
                [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
                mc_xdr_full_frame(enc,hdr,src,1,4);
            }
            mc_present_display_link(enc,link,src,-1);
            require(mc_display_link_drawable(link)==nil,"drawable ownership transferred");
            id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
            [b copyFromTexture:drawable.texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(480,300,1) toBuffer:readback destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:row*300];
            [b endEncoding];
            if (i==100) usleep(25000); // deliberately miss a deadline: no deadlock or corrupt output
            id<MTLCommandBuffer> done = mc_enc_commit(enc);
            completed(done);
            if (mode) {
                _Float16 *px = readback.contents;
                require(px[0] > 1.9 && px[1] > 1.9 && px[2] > 1.9,"full-scene HDR retained above SDR white");
            } else {
                unsigned char *px=readback.contents;
                require(abs(px[0]-191)<=1 && abs(px[1]-128)<=1 && abs(px[2]-64)<=1,"SDR BGRA pixels correct");
            }
            [done release];
            if (i==1350 || i==1450) {
                closeLink(link);
                [window setContentSize:NSMakeSize(i==1350?560:480,300)]; events();
                mc_layer_configure(ctx,layer,480,300,1);
                layer.framebufferOnly = NO;
                link = mc_display_link_create(layer,argc > 1 ? atoi(argv[1]) : 1,1);
                configurePolicy(link);
            }
            if (i==1400) { // hide, bound wait, restore
                mc_display_link_pause(link);
                [window orderOut:nil]; events();
                double hidden=CACurrentMediaTime();
                mc_display_link_begin(link,60);
                require(CACurrentMediaTime()-hidden < .150,"hidden window returns promptly");
                mc_display_link_pause(link);
                [window orderFront:nil]; events();
            }
        } }
        if (!presentationLimited) require(CACurrentMediaTime()-phaseStart >= 120.0/MIN(90,(int)window.screen.maximumFramesPerSecond)*.97,"90 FPS average cap respected");
        if (presentationLimited) { @synchronized(cadence) {
            int caps[] = {120,60,90};
            for (int phase = 0; phase < 3; phase++) {
                require(cadence->shown[phase] >= 50,"enough actual presentation timestamps to check cap");
                double fps = (cadence->shown[phase]-1)/(cadence->last[phase]-cadence->first[phase]);
                fprintf(stdout,"Presented cap %d: %.2f FPS (%u timestamps)\n",caps[phase],fps,cadence->shown[phase]);
                require(fps <= caps[phase]*1.03,"minimum-duration cap respected by actual presentation");
            }
        } }
        fprintf(stdout,"PASS %s: %d callbacks in %.2f s; caps 120/60/90, resize, hide/restore, late frame, pixels\n",mode?"HDR":"SDR",callbacks,CACurrentMediaTime()-start);
        require(callbacks>1500,"callbacks actually arrived");
        closeLink(link);
        require(layer.displaySyncEnabled && layer.maximumDrawableCount == 3,"legacy VSync/drawable count restored");
        runLoopFenceCheck(ctx,enc,layer,src);
        transitionCheck(ctx,enc,layer,src);
        [readback release]; [src release]; [hdr release];
        [cadence release];
    }
    [window close]; [window release];
    puts("PASS: display-link teardown/recreate and live GPU tests");
} return 0; }
