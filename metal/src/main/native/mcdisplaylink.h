// All lifecycle/acquisition calls run on the game's render thread, in a private run-loop mode.
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
void *mc_display_link_create(CAMetalLayer *layer, int latency, int log);
// Returns 0 while encoded frames are still in flight; retain the handle and retry.
// Returns 1 after invalidating/releasing it (also for NULL). Never blocks on the GPU.
int mc_display_link_close(void *handle);
void mc_display_link_pause(void *handle);
int mc_display_link_begin(void *handle, int cap);
id<CAMetalDrawable> mc_display_link_drawable(void *handle); // borrowed until take/pause
id mc_display_link_take(void *handle); // transfers ownership to the frame's command buffer
void mc_display_link_prepare(id frame, id<MTLCommandBuffer> commandBuffer); // before commit
void mc_display_link_present(id frame); // after commit, before targetTimestamp
