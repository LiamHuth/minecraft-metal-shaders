# Experimental ProMotion pacing

Based on `v1.2.5-alpha` (`a5b5a98`), with the shadowed-sun haze correction carried forward separately (`963d36e`). The original HDR fix checkpoint remains on `fix/hdr-sun-haze-occlusion` at `8684b5f`.

1.2.5 includes the HDR/Natural lighting, beacon, MaLiLib and 2160p PRs. It also retains 1.2.4's finite-value protection for the bright sun, lazily creates full-scene HDR passes, separates the highlights/full-scene compositors, improves water-light meshing, and adds thermal/stutter diagnostics. Its presentation backend was unchanged. The haze fix applied without conflicts and its GPU regression passes on this base.

## Try it

Install the test jar in place of the existing Metal Shaders jar. Under **Options → Controls → Key Binds → Metal Shaders**, optionally assign **Toggle full-scene HDR** and **Toggle ProMotion pacing**. Both start unassigned. They work in gameplay, show a brief action-bar status, and save the selected modes in `config/mcopt.properties`. HDR switches between Full scene and Highlights; it does not change window fullscreen or the HDR output setting.

ProMotion starts off unless already configured. You can enable it with the shortcut, or set its startup default in Prism's instance Java arguments:

```
-Dmcopt.metal.displayLink=true
```

Turn **VSync on** and set **Max Framerate to 120** (or your preferred lower cap). Select **ProMotion/Adaptive** refresh in macOS display settings. This is display-driven scheduling; it does not enable adaptive sync on hardware that lacks it, generate frames, or guarantee 120 FPS under a heavy GPU workload.

For an A/B comparison, keep VSync and the FPS cap identical and press the ProMotion shortcut. Switching takes effect at the next frame boundary; no restart is needed. Explicit `-D` arguments still override the saved preference on the next launch. Turning ProMotion off keeps the 1.2.5 HDR changes and the haze fix while using the original pacing/presentation path. VSync off also uses the legacy path.

Optional:

- `-Dmcopt.metal.displayLink.latency=2`: request Apple's two-frame GPU budget instead of one. May help a heavy workload but can increase latency.
- `-Dmcopt.metal.displayLink.log=false`: disable the periodic native pacing report.

## Behavior

The game waits for `CAMetalDisplayLink` before SDL input polling. The link supplies the drawable; this path never calls `nextDrawable`. The normal HDR/SDR presentation shaders draw directly into it. After committing the frame, the drawable is presented before the update's CPU deadline when possible. This avoids the separate staging/presentation queue and the old after-render pacer in this mode.

The preferred rate follows the window's display maximum and the game's current cap. A timestamp grid enforces the average cap if the OS rounds a request upward (observed with 90 requested on a 120 Hz panel). Minecraft's own lower menu cap still applies. The ordinary limiter remains available if the cap drops mid-frame. Caps below 30, minimization, and VSync off return to the legacy path.

Lifecycle, callbacks and rendering stay on the game thread. A private run-loop mode also runs Core Animation's common-mode observers, so layer transactions continue to reach the compositor. Resize/HDR reconfiguration invalidates the link before altering layer properties; merely pausing is insufficient for `maximumDrawableCount`. Invalidation happens exactly once. Legacy presentation is drained before the link takes over acquisition. Callback waits are bounded to 50 ms; three consecutive timeouts return to the legacy path with a later retry.

## Measurements and validation

The native report appears in Prism's console/stderr every 10 seconds while the link remains active. It includes the requested rate, valid presentation timestamps, average and p95 display intervals, callback-to-display time, late CPU commits, missing drawables/timestamps, and GPU errors. P95 uses 0.5 ms histogram bins (values above 127.5 ms share the final bin). Missing timestamps are counted separately; they are not treated as successful measurements. Callback-to-display is **not** a measurement of physical input-to-photon latency. Windowed macOS compositing may add buffering despite a one-frame preference.

Existing `mcopt.metal.gpuTimes` / `mcopt.own.int.frameLog` instrumentation works with both paths, including the provided drawable's presentation timestamp. Compare stable runs at the same window size, HDR mode, scene, FPS cap and power settings. Exclude startup, shader compilation, resize and other transitions. Compare displayed-frame intervals and hitches, rather than relying on the rendered FPS counter.

Build first, then run `sh tools/presentation/run.sh [output-directory] [latency:1|2]`. This opens a temporary test window and uses the actual native backend with Metal API validation. It exercises SDR and full-scene HDR pixels above SDR white, sustained 120 Hz requests, 60/90 FPS caps, a missed deadline, resizing, hide/restore, and teardown/recreation. The scene is deliberately tiny: it tests presentation and does not establish Minecraft performance gains.

Also run `sh tools/shade/hazecheck/run.sh` and `sh tools/shade/hdrcheck/run.sh`. The in-game smoke test used an isolated offline Minecraft 26.3/Fabric 0.19.5 profile, checking mixin application, menu rendering, resize, VSync off/on and graceful shutdown. Offline authentication/Realms errors are unrelated to rendering.

The hotkey build was also exercised in an isolated superflat world with Metal API validation: unassigned defaults, translated Controls labels without Fabric API, assignment save/load, Full scene/Highlights switching, repeated live ProMotion toggles, chat suppression, VSync changes, resizing, and saved preferences after restarting. This exposed two existing terrain-validation issues: disabled exact-culling arguments had no buffers, and the disabled TUnit buffers were smaller than one element. Both now have valid bindings/sizes without enabling those optional paths.

Still needs real-world testing: sustained gameplay on the external Studio Display XDR, fullscreen transitions, moving the game between displays, sleep/wake, and heavily GPU-bound worlds. Lower input latency is a goal to measure, not a result claimed by this prototype.

API references: [CAMetalDisplayLink](https://developer.apple.com/documentation/quartzcore/cametaldisplaylink), [targetTimestamp](https://developer.apple.com/documentation/quartzcore/cametaldisplaylink/update/targettimestamp), [preferredFrameLatency](https://developer.apple.com/documentation/quartzcore/cametaldisplaylink/preferredframelatency).
