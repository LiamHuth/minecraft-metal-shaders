// Copyright 2026 mcopt-shade contributors. Apache-2.0.
// Exercise the production ray march against a uniformly blocked/open shadow map.
// cfg: distance, forest density, upward view slope, shadow transition (0 = uniform).
kernel void haze_fixture(device ShadeFrame &f [[buffer(0)]], device ShadeLook &l [[buffer(1)]],
                         device VlParams &p [[buffer(2)]], constant float4 &cfg [[buffer(3)]]) {
    f = {}; l = {}; p = {};
    f.invViewProj = float4x4(float4(0.1,0,0,0), float4(0,0.1,0,0), float4(0,0,0,20), float4(0,cfg.z,-1,0));
    f.shadowViewProj[0] = f.shadowViewProj[1] = float4x4(float4(0), float4(0), float4(0,0,-cfg.w,0), float4(0,0,0.5,1));
    f.cameraBlock.y = 64;
    f.lightDirWorld = float4(normalize(float3(0,0.05,-1)),1);
    f.sunColor = float4(10,5,1,1);
    f.ambientSky = float4(0.2,0.3,0.4,0);
    f.flags.z = 1;
    l.fogR = float4(0.0001,0.0002,0.0004,100);
    l.fogM = float4(0.001,10,64,0.9);
    l.fogMisc = float4(64,0,0,0.6);
    l.clock2 = float4(0,1,1,1);
    l.tier.y = SHADE_FEATURE_HAZE;
    l.clouds1.z = float(SHADE_CLOUD_DEV_NO_VL);
    p.size = float4(8);
    p.shape = float4(1,512,26,0.5);
    p.light = float4(10,5,1,cfg.y);
    p.gate.z = 1;
    p.mist.w = 1;
    p.air = float4(1,8,0.1,26);
    p.air2 = float4(512,0,1,0); // isolate the haze correction; no added forest lighting
    p.grid = float4(-128,-48,-128,4);
    p.air3 = float4(0.3,0.85,24,0);
    p.air5 = float4(48,96,1,0);
}

// Compare the marched correction with the exact haze the final pass adds at the
// same depth. result = remaining sunlight / unshadowed sunlight, per channel.
kernel void haze_measure(constant ShadeFrame &f [[buffer(16)]], constant ShadeLook &l [[buffer(17)]],
                         texture2d<half> march [[texture(0)]], depth2d<float> depth [[texture(1)]],
                         device float4 *result [[buffer(0)]], uint2 px [[thread_position_in_grid]]) {
    float2 ndc = (float2(px)+0.5)/8.0*2.0-1.0;
    float4 h = f.invViewProj * float4(ndc,depth.read(px),1);
    float3 t, sun;
    float3 haze = shadeHazeInscatter(h.xyz/h.w,f,l,1,t,sun);
    float3 corrected = haze + float3(march.read(px).rgb);
    result[px.y*8+px.x] = float4((corrected-(haze-sun))/max(sun,1e-8),1);
}
