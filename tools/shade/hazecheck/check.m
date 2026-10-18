// Copyright 2026 mcopt-shade contributors. Apache-2.0.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <math.h>

static void check(BOOL ok, NSString *what) {
    if (!ok) { fprintf(stderr,"FAIL %s\n",what.UTF8String); exit(1); }
}
static void complete(id<MTLCommandBuffer> cb) {
    [cb commit]; [cb waitUntilCompleted];
    check(cb.status == MTLCommandBufferStatusCompleted, cb.error.description ?: @"GPU completion");
}
static void clearDepth(id<MTLCommandBuffer> cb, id<MTLTexture> t, int slice, float d) {
    MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor renderPassDescriptor];
    rp.depthAttachment.texture=t; rp.depthAttachment.slice=slice;
    rp.depthAttachment.loadAction=MTLLoadActionClear; rp.depthAttachment.storeAction=MTLStoreActionStore;
    rp.depthAttachment.clearDepth=d;
    [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
}

int main(int argc, const char **argv) { @autoreleasepool {
    check(argc==3,@"usage: hazecheck vl.metal probe.metal");
    id<MTLDevice> dev=MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> queue=[dev newCommandQueue];
    NSError *error=nil;
    NSString *source=[NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:&error];
    NSString *probe=[NSString stringWithContentsOfFile:@(argv[2]) encoding:NSUTF8StringEncoding error:&error];
    check(source && probe,@"read shader source");
    MTLCompileOptions *opts=[MTLCompileOptions new];
    opts.languageVersion=MTLLanguageVersion3_0; opts.mathMode=MTLMathModeFast;
    id<MTLLibrary> lib=[dev newLibraryWithSource:[source stringByAppendingString:probe] options:opts error:&error];
    check(lib!=nil,error.description);
    id<MTLComputePipelineState> fixture=[dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"haze_fixture"] error:&error];
    id<MTLComputePipelineState> measure=[dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"haze_measure"] error:&error];
    check(fixture && measure,error.description);
    bool hdr=true;
    MTLFunctionConstantValues *fc=[MTLFunctionConstantValues new];
    [fc setConstantValue:&hdr type:MTLDataTypeBool atIndex:0];
    id<MTLFunction> fs=[lib newFunctionWithName:@"vl_march" constantValues:fc error:&error];
    MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];
    pd.vertexFunction=[lib newFunctionWithName:@"vl_vs"]; pd.fragmentFunction=fs;
    pd.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA16Float;
    pd.colorAttachments[1].pixelFormat=MTLPixelFormatR8Unorm;
    id<MTLRenderPipelineState> march=[dev newRenderPipelineStateWithDescriptor:pd error:&error];
    check(march!=nil,error.description);
    id<MTLBuffer> f=[dev newBufferWithLength:2048 options:MTLResourceStorageModeShared];
    id<MTLBuffer> l=[dev newBufferWithLength:2048 options:MTLResourceStorageModeShared];
    id<MTLBuffer> p=[dev newBufferWithLength:1024 options:MTLResourceStorageModeShared];
    id<MTLBuffer> st=[dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
    id<MTLBuffer> result=[dev newBufferWithLength:64*16 options:MTLResourceStorageModeShared];
    MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:8 height:8 mipmapped:NO];
    td.storageMode=MTLStorageModeShared; td.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;
    id<MTLTexture> raw=[dev newTextureWithDescriptor:td], lut=[dev newTextureWithDescriptor:td];
    td.pixelFormat=MTLPixelFormatR8Unorm;
    id<MTLTexture> sky=[dev newTextureWithDescriptor:td];
    td.pixelFormat=MTLPixelFormatDepth32Float; td.storageMode=MTLStorageModePrivate;
    id<MTLTexture> depth=[dev newTextureWithDescriptor:td];
    td.textureType=MTLTextureType2DArray; td.arrayLength=2;
    id<MTLTexture> shadow=[dev newTextureWithDescriptor:td];
    td.textureType=MTLTextureType3D; td.arrayLength=1; td.width=td.height=td.depth=1;
    td.pixelFormat=MTLPixelFormatR8Unorm; td.storageMode=MTLStorageModeShared; td.usage=MTLTextureUsageShaderRead;
    id<MTLTexture> grid=[dev newTextureWithDescriptor:td];
    uint8_t zero=0; [grid replaceRegion:MTLRegionMake3D(0,0,0,1,1,1) mipmapLevel:0 slice:0 withBytes:&zero bytesPerRow:1 bytesPerImage:1];
    uint16_t empty[8*8*4]={0};
    [lut replaceRegion:MTLRegionMake2D(0,0,8,8) mipmapLevel:0 withBytes:empty bytesPerRow:8*8];
    id<MTLArgumentEncoder> args=[fs newArgumentEncoderWithBufferIndex:19];
    id<MTLBuffer> resources=[dev newBufferWithLength:args.encodedLength options:MTLResourceStorageModeShared];
    [args setArgumentBuffer:resources offset:0];
    for(int i=0;i<16;i++) [args setTexture:lut atIndex:i];
    MTLSamplerDescriptor *sd=[MTLSamplerDescriptor new];
    sd.minFilter=sd.magFilter=MTLSamplerMinMagFilterLinear;
    sd.sAddressMode=sd.tAddressMode=MTLSamplerAddressModeClampToEdge;
    id<MTLSamplerState> linear=[dev newSamplerStateWithDescriptor:sd];
    sd.compareFunction=MTLCompareFunctionGreaterEqual;
    id<MTLSamplerState> cmp=[dev newSamplerStateWithDescriptor:sd];
    float worst=0; int failed=0, count=0;
    for(int mode=0;mode<3;mode++) for(int distance=0;distance<4;distance++)
    for(int mist=0;mist<3;mist++) for(int slope=0;slope<3;slope++) {
        float cfg[4]={(float[]){16,64,128,256}[distance],(float[]){0,.017,.07}[mist],(float[]){0,.4,-.3}[slope],mode==2?.002:0};
        id<MTLCommandBuffer> cb=[queue commandBuffer];
        clearDepth(cb,depth,0,.05f/cfg[0]);
        for(int s=0;s<2;s++) clearDepth(cb,shadow,s,mode==1?.25:.65);
        id<MTLComputeCommandEncoder> c=[cb computeCommandEncoder];
        [c setComputePipelineState:fixture]; [c setBuffer:f offset:0 atIndex:0]; [c setBuffer:l offset:0 atIndex:1];
        [c setBuffer:p offset:0 atIndex:2]; [c setBytes:cfg length:sizeof cfg atIndex:3];
        [c dispatchThreads:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)]; [c endEncoding];
        MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture=raw; rp.colorAttachments[1].texture=sky;
        for(int i=0;i<2;i++) { rp.colorAttachments[i].loadAction=MTLLoadActionDontCare; rp.colorAttachments[i].storeAction=MTLStoreActionStore; }
        id<MTLRenderCommandEncoder> r=[cb renderCommandEncoderWithDescriptor:rp];
        [r setRenderPipelineState:march];
        [r setFragmentBuffer:p offset:0 atIndex:0]; [r setFragmentBuffer:st offset:0 atIndex:1];
        [r setFragmentBuffer:f offset:0 atIndex:16]; [r setFragmentBuffer:l offset:0 atIndex:17];
        [r setFragmentBuffer:resources offset:0 atIndex:19]; [r useResource:lut usage:MTLResourceUsageRead stages:MTLRenderStageFragment];
        [r setFragmentTexture:depth atIndex:0]; [r setFragmentTexture:lut atIndex:1]; [r setFragmentTexture:grid atIndex:2];
        [r setFragmentTexture:shadow atIndex:16]; [r setFragmentTexture:lut atIndex:17];
        [r setFragmentSamplerState:cmp atIndex:12]; [r setFragmentSamplerState:linear atIndex:13];
        [r drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [r endEncoding];
        c=[cb computeCommandEncoder]; [c setComputePipelineState:measure];
        [c setBuffer:result offset:0 atIndex:0]; [c setBuffer:f offset:0 atIndex:16]; [c setBuffer:l offset:0 atIndex:17];
        [c setTexture:raw atIndex:0]; [c setTexture:depth atIndex:1];
        [c dispatchThreads:MTLSizeMake(8,8,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)]; [c endEncoding]; complete(cb);
        float *v=result.contents, residual=0; BOOL ok=YES;
        for(int i=0;i<64;i++) for(int k=0;k<3;k++) {
            float x=v[i*4+k]; residual=fmaxf(residual,fabsf(x));
            ok &= isfinite(x) && (mode==0 ? fabsf(x)<.002 : mode==1 ? fabsf(x-1)<.002 : x>-.002 && x<1.002);
        }
        if(mode==0) worst=fmaxf(worst,residual);
        if(!ok) { failed++; printf("FAIL mode %d distance %.0f mist %.3f slope %.1f: sunlight remaining %.2f%%\n",mode,cfg[0],cfg[1],cfg[2],residual*100); }
        count++;
    }
    printf("%s %d GPU cases: blocked/open/partial sun, varying distance, height and mist; worst fully shadowed residual %.3f%%\n",failed?"FAIL":"OK",count,worst*100);
    return failed?1:0;
} }
