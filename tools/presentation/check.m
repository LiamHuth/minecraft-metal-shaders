// Live-window test of the production display-link and native present/commit paths.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import "mcmetal.h"
#import "mcdisplaylink.h"
#include <assert.h>
#include <unistd.h>
Ctx *mc_create(char *, int, char *, int);
Enc *mc_enc_new(Ctx *);
void mc_layer_configure(Ctx *, CAMetalLayer *, int, int, int);
void mc_present_display_link(Enc *, void *, id<MTLTexture>, long);
id<MTLCommandBuffer> mc_enc_commit(Enc *);
void mc_xdr_enable(int);
void mc_xdr_full_frame(Enc *, id<MTLTexture>, id<MTLTexture>, float, float);
static void events(void) {
    NSEvent *event;
    while ((event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate distantPast] inMode:NSDefaultRunLoopMode dequeue:YES])) [NSApp sendEvent:event];
    [NSApp updateWindows];
}
static void require(BOOL ok, const char *msg) { if (!ok) { fprintf(stderr,"FAIL: %s\n",msg); exit(1); } }
int main(int argc, const char **argv) { @autoreleasepool {
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
    [window orderFront:nil]; events();
    for (int mode = 0; mode < 2; mode++) {
        mc_xdr_enable(mode);
        mc_layer_configure(ctx,layer,480,300,1);
        layer.framebufferOnly = NO; // read back the actual presented drawable to verify colour
        void *link = mc_display_link_create(layer,argc > 1 ? atoi(argv[1]) : 1,1);
        require(link != NULL,"create display link");
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
                require(CACurrentMediaTime()-phaseStart >= frames/(double)ceiling*.97,"120/60 FPS average cap respected");
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
            [done waitUntilCompleted];
            require(done.status == MTLCommandBufferStatusCompleted,"GPU command completed");
            if (mode) {
                _Float16 *px = readback.contents;
                require(px[0] > 1.9 && px[1] > 1.9 && px[2] > 1.9,"full-scene HDR retained above SDR white");
            } else {
                unsigned char *px=readback.contents;
                require(abs(px[0]-191)<=1 && abs(px[1]-128)<=1 && abs(px[2]-64)<=1,"SDR BGRA pixels correct");
            }
            [done release];
            if (i==1350 || i==1450) {
                mc_display_link_close(link);
                [window setContentSize:NSMakeSize(i==1350?560:480,300)]; events();
                mc_layer_configure(ctx,layer,480,300,1);
                layer.framebufferOnly = NO;
                link = mc_display_link_create(layer,argc > 1 ? atoi(argv[1]) : 1,1);
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
        require(CACurrentMediaTime()-phaseStart >= 120.0/MIN(90,(int)window.screen.maximumFramesPerSecond)*.97,"90 FPS average cap respected");
        fprintf(stdout,"PASS %s: %d callbacks in %.2f s; caps 120/60/90, resize, hide/restore, late frame, pixels\n",mode?"HDR":"SDR",callbacks,CACurrentMediaTime()-start);
        require(callbacks>1500,"callbacks actually arrived");
        mc_display_link_close(link);
        [readback release]; [src release]; [hdr release];
    }
    [window close]; [window release];
    puts("PASS: display-link teardown/recreate and live GPU tests");
} return 0; }
