// Read-only benchmark context. No layer/window mutation or GPU work.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#include <stdint.h>
#include <string.h>

static CAMetalLayer *metalLayer(CALayer *layer) {
    if ([layer isKindOfClass:CAMetalLayer.class]) return (CAMetalLayer *)layer;
    for (CALayer *child in layer.sublayers) {
        CAMetalLayer *found = metalLayer(child);
        if (found) return found;
    }
    return nil;
}
static CAMetalLayer *viewLayer(NSView *view) {
    CAMetalLayer *found = metalLayer(view.layer);
    if (found) return found;
    for (NSView *child in view.subviews) {
        found = viewLayer(child);
        if (found) return found;
    }
    return nil;
}
int bench_context(uintptr_t pointer, char *destination, int capacity) {
    if (!pointer || !destination || capacity <= 0 || !NSThread.isMainThread) return 0;
    NSWindow *window = (NSWindow *)pointer;
    NSScreen *screen = window.screen;
    CAMetalLayer *layer = viewLayer(window.contentView);
    if (!screen || !layer) return 0;
    NSDictionary *context = @{
        @"nativeFullscreen": @((BOOL)((window.styleMask & NSWindowStyleMaskFullScreen) != 0)),
        @"focused": @(window.keyWindow), @"visible": @(window.visible),
        @"screen": screen.localizedName, @"maximumFPS": @(screen.maximumFramesPerSecond),
        @"minimumRefreshInterval": @(screen.minimumRefreshInterval),
        @"maximumRefreshInterval": @(screen.maximumRefreshInterval),
        @"updateGranularity": @(screen.displayUpdateGranularity),
        @"drawableWidth": @(layer.drawableSize.width), @"drawableHeight": @(layer.drawableSize.height),
        @"pixelFormat": @(layer.pixelFormat), @"hdr": @(layer.wantsExtendedDynamicRangeContent),
        @"vsync": @(layer.displaySyncEnabled), @"drawableCount": @(layer.maximumDrawableCount)
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:context options:0 error:nil];
    if (!json || json.length >= (NSUInteger)capacity) return 0;
    memcpy(destination, json.bytes, json.length); destination[json.length] = 0;
    return 1;
}
