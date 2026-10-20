// Short presentation-only experiment. Fullscreen is entered BEFORE the Metal
// layer/link exists; no live HDR/VSync/fullscreen toggles occur while it is active.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import "mcmetal.h"
#import "mcdisplaylink.h"
#include <unistd.h>
Ctx *mc_create(char *, int, char *, int);
Enc *mc_enc_new(Ctx *);
void mc_layer_configure(Ctx *, CAMetalLayer *, int, int, int);
void mc_present_display_link(Enc *, void *, id<MTLTexture>, long);
id<MTLCommandBuffer> mc_enc_commit(Enc *);
void mc_xdr_enable(int);
void mc_xdr_full_frame(Enc *, id<MTLTexture>, id<MTLTexture>, float, float);
void bench_load(Enc *, uintptr_t, int);
typedef struct { double input, gpuStart, gpuEnd, shown, notified; int phase, focused; } Sample;
@interface ProbeTrace : NSObject {
@public Sample samples[20000]; unsigned count;
}
@end
@implementation ProbeTrace
@end
static uint64_t heartbeat;
static void beat(void) { __atomic_store_n(&heartbeat, (uint64_t)(CACurrentMediaTime()*1e9), __ATOMIC_RELEASE); }
static void require(BOOL ok, const char *message) { if (!ok) { fprintf(stderr,"FAIL: %s\n",message); exit(1); } }
static void events(void) {
    NSEvent *event;
    while ((event=[NSApp nextEventMatchingMask:NSEventMaskAny untilDate:NSDate.distantPast inMode:NSDefaultRunLoopMode dequeue:YES]))
        [NSApp sendEvent:event];
    [NSApp updateWindows];
    beat();
}
int main(int argc, const char **argv) { @autoreleasepool {
    require(argc==3,"usage: adaptive-probe windowed|fullscreen output.json");
    BOOL fullscreen = strcmp(argv[1],"fullscreen")==0;
    require(fullscreen || strcmp(argv[1],"windowed")==0,"known window mode");
    beat();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        for (;;) {
            usleep(250000);
            double last=__atomic_load_n(&heartbeat,__ATOMIC_ACQUIRE)/1e9;
            if (CACurrentMediaTime()-last>8) { fputs("FAIL: test process stopped progressing\n",stderr); _exit(70); }
        }
    });
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [NSApp finishLaunching];
    NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(100,100,640,400)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    window.title=@"Metal Shaders — adaptive presentation probe";
    window.collectionBehavior=NSWindowCollectionBehaviorFullScreenPrimary;
    window.releasedWhenClosed=NO;
    [window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
    if (fullscreen) [window toggleFullScreen:nil];
    double settle=CACurrentMediaTime()+2;
    while (CACurrentMediaTime()<settle) { events(); CFRunLoopRunInMode(kCFRunLoopDefaultMode,.002,true); }
    require(((window.styleMask & NSWindowStyleMaskFullScreen)!=0)==fullscreen,"requested native fullscreen state reached");
    require(window.keyWindow,"test window focused");
    NSView *view=window.contentView; view.wantsLayer=YES;
    CAMetalLayer *layer=[CAMetalLayer layer]; view.layer=layer;
    char name[256],error[1024]; Ctx *ctx=mc_create(name,sizeof(name),error,sizeof(error));
    require(ctx!=NULL,error); Enc *enc=mc_enc_new(ctx);
    mc_xdr_enable(1); mc_layer_configure(ctx,layer,1280,800,1);
    require(layer.displaySyncEnabled && layer.maximumDrawableCount==3,"VSync and original drawable pool");
    MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1280 height:800 mipmapped:NO];
    td.usage=MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget;
    id<MTLTexture> src=[ctx->device newTextureWithDescriptor:td];
    td.pixelFormat=MTLPixelFormatRGBA16Float; td.usage|=MTLTextureUsageShaderWrite;
    id<MTLTexture> hdr=[ctx->device newTextureWithDescriptor:td];
    NSString *shader=@"#include <metal_stdlib>\nusing namespace metal;\n"
      "kernel void stripe(texture2d<half,access::write> out [[texture(0)]], constant float &x [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {"
      "if(p.x>=out.get_width()||p.y>=out.get_height())return;float v=abs(float(p.x)-x)<25?1.5:.15;out.write(half4(v,v,v,1),p);}";
    NSError *err=nil; id<MTLLibrary> lib=[ctx->device newLibraryWithSource:shader options:nil error:&err];
    id<MTLFunction> fn=[lib newFunctionWithName:@"stripe"];
    id<MTLComputePipelineState> pipeline=[ctx->device newComputePipelineStateWithFunction:fn error:&err];
    require(pipeline!=nil,"probe shader compiled"); [fn release]; [lib release];
    ProbeTrace *trace=[ProbeTrace new]; NSMutableArray *phases=[NSMutableArray new];
    NSMutableArray<id<MTLCommandBuffer>> *pending=[NSMutableArray new];
    void *link=mc_display_link_create(layer,0,1); require(link!=NULL,"presentation initialized");
    int modes[]={1,2,2,3}, queues[]={0,0,3,3};
    int phase=0;
    for (int workload=0;workload<3;workload++) for (int policy=0;policy<4;policy++,phase++) { @autoreleasepool {
        int cap=workload==0?50:workload==1?83:120;
        mc_display_link_configure(link,modes[policy],queues[policy]);
        double begin=CACurrentMediaTime(), measure=begin+1, end=measure+4;
        fprintf(stderr,"PROBE phase=%d cap=%d policy=%d queue=%d load=%d\n",phase,cap,modes[policy],queues[policy],workload==2);
        [phases addObject:@{@"phase":@(phase),@"cap":@(cap),@"policy":@(modes[policy]),@"queue":@(queues[policy]),
            @"variableGpuLoad":@(workload==2),@"begin":@(measure),@"end":@(end)}];
        while (CACurrentMediaTime()<end) { @autoreleasepool {
            events();
            while (pending.count && (pending[0].status>=MTLCommandBufferStatusCompleted || pending.count>=2)) {
                id<MTLCommandBuffer> done=pending[0];
                mc_cmd_wait(done); require(done.status==MTLCommandBufferStatusCompleted,"GPU succeeded");
                [pending removeObjectAtIndex:0];
            }
            if (!mc_display_link_begin(link,cap)) continue;
            double input=CACurrentMediaTime();
            require(trace->count<20000,"trace capacity"); unsigned slot=trace->count++;
            trace->samples[slot]=(Sample){.input=input,.phase=phase,.focused=window.keyWindow};
            id<CAMetalDrawable> drawable=mc_display_link_drawable(link);
            id<MTLCommandBuffer> cb=mc_frame_cmd(enc);
            id<MTLComputeCommandEncoder> compute=[cb computeCommandEncoder];
            float x=(float)fmod(input*240,1280);
            [compute setComputePipelineState:pipeline]; [compute setTexture:hdr atIndex:0];
            [compute setBytes:&x length:sizeof(x) atIndex:0];
            [compute dispatchThreads:MTLSizeMake(1280,800,1) threadsPerThreadgroup:MTLSizeMake(16,8,1)]; [compute endEncoding];
            mc_xdr_full_frame(enc,hdr,src,1,4);
            mc_present_display_link(enc,link,src,-1);
            if (workload==2) {
                // Time-based load: each policy sees the same sequence despite FPS differences.
                int rounds[]={8000,12000,18000,24000};
                int step=(int)((input-begin)*4);
                bench_load(enc,(uintptr_t)mc_frame_cmd,step%11==0?32000:rounds[step%4]);
            }
            [cb addCompletedHandler:^(id<MTLCommandBuffer> done) { @synchronized(trace) {
                trace->samples[slot].gpuStart=done.GPUStartTime; trace->samples[slot].gpuEnd=done.GPUEndTime;
            } }];
            [drawable addPresentedHandler:^(id<MTLDrawable> d) { @synchronized(trace) {
                trace->samples[slot].shown=d.presentedTime; trace->samples[slot].notified=CACurrentMediaTime();
            } }];
            id<MTLCommandBuffer> done=mc_enc_commit(enc); [pending addObject:done]; [done release];
        } }
    } }
    for (id<MTLCommandBuffer> cb in pending) mc_cmd_wait(cb);
    [pending removeAllObjects];
    double stop=CACurrentMediaTime()+1;
    while (CACurrentMediaTime()<stop) { events(); CFRunLoopRunInMode(CFSTR("mcopt.display-link"),.001,true); }
    while (!mc_display_link_close(link)) { events(); require(CACurrentMediaTime()<stop+2,"bounded teardown"); }
    NSMutableArray *rows=[NSMutableArray new];
    @synchronized(trace) { for (unsigned i=0;i<trace->count;i++) {
        Sample s=trace->samples[i];
        [rows addObject:@[@(s.phase),@(s.input),@(s.gpuStart),@(s.gpuEnd),@(s.shown),@(s.notified),@(s.focused)]];
    } }
    NSScreen *screen=window.screen;
    NSDictionary *report=@{@"fullscreen":@(fullscreen),@"hdr":@(layer.wantsExtendedDynamicRangeContent),
        @"screen":screen.localizedName,@"maximumFPS":@(screen.maximumFramesPerSecond),
        @"minimumRefreshInterval":@(screen.minimumRefreshInterval),@"maximumRefreshInterval":@(screen.maximumRefreshInterval),
        @"updateGranularity":@(screen.displayUpdateGranularity),@"phases":phases,@"samples":rows,
        @"columns":@[@"phase",@"input",@"gpuStart",@"gpuEnd",@"presentedTime",@"notificationTime",@"focused"]};
    NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:&err];
    require(json && [json writeToFile:[NSString stringWithUTF8String:argv[2]] atomically:YES],"report saved");
    [window close];
    puts("PROBE PASS");
    // Process exit owns the isolated renderer; pending callbacks retain their trace.
} return 0; }
