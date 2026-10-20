// Test-only GPU workload. Linked by the isolated benchmark, never packaged in the mod.
#import "mcmetal.h"
#include <stdio.h>
static id<MTLComputePipelineState> pipeline;
static id<MTLBuffer> output;
static void setup(id<MTLDevice> device) {
    if (pipeline) return;
    NSError *error = nil;
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void load(device float *out [[buffer(0)]], constant uint &rounds [[buffer(1)]], uint tid [[thread_position_in_grid]]) {"
        "float x=float(tid)*.00001f; for(uint i=0;i<rounds;i++) x=fma(x,1.0000001f,float((tid+i)&31u)*.00001f); out[tid]=x;}";
    id<MTLLibrary> lib = [device newLibraryWithSource:source options:nil error:&error];
    id<MTLFunction> fn = [lib newFunctionWithName:@"load"];
    pipeline = [device newComputePipelineStateWithFunction:fn error:&error];
    [fn release]; [lib release];
    if (!pipeline) { fprintf(stderr,"GPU load setup failed: %s\n", error.description.UTF8String); abort(); }
    output = [device newBufferWithLength:262144*sizeof(float) options:MTLResourceStorageModePrivate];
}
void bench_load(Enc *enc, uintptr_t frameCommand, int rounds) {
    if (rounds <= 0 || rounds > 50000) return;
    setup(enc->ctx->device);
    id<MTLCommandBuffer> (*frame)(Enc *) = (void *)frameCommand;
    id<MTLComputeCommandEncoder> compute = [frame(enc) computeCommandEncoder];
    compute.label = @"Pacing benchmark variable GPU workload";
    [compute setComputePipelineState:pipeline];
    [compute setBuffer:output offset:0 atIndex:0];
    [compute setBytes:&rounds length:sizeof(rounds) atIndex:1];
    [compute dispatchThreads:MTLSizeMake(262144,1,1) threadsPerThreadgroup:MTLSizeMake(128,1,1)];
    [compute endEncoding];
}
#ifdef CALIBRATE
static id<MTLCommandBuffer> current;
static id<MTLCommandBuffer> frame(Enc *enc) { return current; }
int main(void) { @autoreleasepool {
    Ctx ctx={0}; ctx.device=MTLCreateSystemDefaultDevice(); Enc enc={0}; enc.ctx=&ctx;
    id<MTLCommandQueue> queue=[ctx.device newCommandQueue];
    int rounds[]={1000,4000,12000,24000,48000};
    for(int i=0;i<5;i++) { current=[queue commandBuffer]; bench_load(&enc,(uintptr_t)frame,rounds[i]); [current commit]; [current waitUntilCompleted];
        if(current.status!=MTLCommandBufferStatusCompleted)return 1;
        printf("%d rounds: %.3f ms\n",rounds[i],(current.GPUEndTime-current.GPUStartTime)*1000);
    }
} }
#endif
