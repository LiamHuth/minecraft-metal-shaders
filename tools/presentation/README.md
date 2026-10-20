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

For an A/B comparison, keep VSync and the FPS cap identical and press the ProMotion shortcut. Switching starts at the next frame boundary and completes after outstanding presentation frames finish; no restart is needed. The action bar confirms the actual state for a few seconds after toggling, and F3 shows it continuously: **Active**, **Off**, **Switching**, or the reason it is waiting/using the standard fallback. An enabled preference alone does not mean display-link pacing is active. Explicit `-D` arguments still override the saved preference on the next launch. Turning ProMotion off keeps the 1.2.5 HDR changes and the haze fix while using the original pacing/presentation path. VSync off also uses the legacy path.

The old `mcopt.metal.displayLink.latency` option has no effect with the new callback-only pacer.

Optional:

- `-Dmcopt.metal.displayLink.log=false`: disable the periodic native pacing report.

## Behavior

The game uses a window-following `CADisplayLink` as a clock and measures input-ready-to-GPU-completion time to choose when to begin the next frame. It waits before SDL input polling, then acquires an ordinary layer drawable. The layer keeps VSync and its original drawable pool while pacing is enabled. Acquisition backpressure therefore precedes input sampling. Presentation uses the same `MTLCommandBuffer.presentDrawable` scheduling as the legacy renderer, without an extra presentation target imposed by `CAMetalDisplayLink`. HDR/SDR composition is unchanged. Pacing does not change the configured drawable count.

The callback rate requests the window's display maximum, independently of the user's FPS cap. A timestamp grid enforces the average cap without catch-up bursts. The render budget uses the recent p90 CPU/GPU elapsed time with a small wake-up margin; it rises promptly and falls gradually. Work is scheduled ahead of a display opportunity when it fits. If a slow frame has already consumed the cap period, the next frame does not wait for another callback. The clock uses the observed callback interval, rather than assuming the requested rate was granted. This avoids asking macOS for 50 Hz, receiving 60 Hz callbacks, then skipping to 33.3 ms intervals; a 120 Hz callback grid offers finer 16.7/25 ms intervals. The system still chooses the actual cadence. Minecraft's lower menu cap applies; the ordinary limiter remains available if the cap drops mid-frame. Caps below 30, minimization, and VSync off return to the legacy path.

Windowed cadence improvements do not establish physical Adaptive Sync. Apple's external-display Adaptive Sync guidance also requires fullscreen and a variable refresh display mode. Fullscreen and external-display behavior must be validated separately.

Lifecycle, callbacks and rendering stay on the game thread. A private run-loop mode also runs Core Animation's common-mode observers, so layer transactions continue to reach the compositor. Disabling, resizing, and fallback first retire the link: stop acquiring frames, keep every encoded drawable and its command buffer alive, and poll completion at frame boundaries. This includes frames encoded but not yet committed. Until completion, presentation is skipped and the layer remains unchanged. Only then is the link paused, invalidated exactly once and released, and the Core Animation transaction flushed before ordinary drawable acquisition resumes. Pending resize/VSync configurations are coalesced during retirement. Close attempts service the private run-loop mode with a 1 ms budget before checking completion again. Renderer GPU fences also service that mode while a link remains registered, including during retirement and shutdown. Layer reconfiguration waits for retirement. Legacy presentation is drained before the link takes over acquisition. Callback waits are bounded to 50 ms; ordinary `nextDrawable` acquisition retains the layer's system timeout. Three consecutive timeouts request a return to the legacy path with a later retry.

## Measurements and validation

The native report appears in Prism's console/stderr every 10 seconds while the link remains active. It includes the requested rate, valid presentation timestamps, average and p95 display intervals, start-to-display time, commits after the estimated finish, missing drawables/timestamps, and GPU errors. P95 uses 0.5 ms histogram bins (values above 127.5 ms share the final bin). Missing timestamps are counted separately; they are not treated as successful measurements. Start-to-display is **not** a measurement of physical input-to-photon latency. Windowed macOS compositing still adds buffering; callback targets are not physical scanout timestamps.

Existing `mcopt.metal.gpuTimes` / `mcopt.own.int.frameLog` instrumentation works with both paths, including the provided drawable's presentation timestamp. Compare stable runs at the same window size, HDR mode, scene, FPS cap and power settings. Exclude startup, shader compilation, resize and other transitions. Compare displayed-frame intervals and hitches, rather than relying on the rendered FPS counter.

Build first, then run `sh tools/presentation/run.sh [output-directory] [latency:1|2]`. This opens a temporary test window and uses the actual native backend with Metal API validation. It exercises SDR and full-scene HDR pixels above SDR white, sustained 120 Hz requests, 60/90 FPS caps, a missed deadline, resizing, hide/restore, and teardown/recreation. For each output format it also performs twelve transitions with a command buffer deliberately held by a CPU-signalled Metal shared event. Closing must defer both before commit and while the GPU is waiting, and ordinary presentation must work after releasing the event. An unused acquired drawable is checked separately. Completion checks are bounded, so a regression fails the harness rather than waiting forever. The scene is deliberately tiny: it tests presentation and does not establish Minecraft performance gains.

Also run `sh tools/shade/hazecheck/run.sh` and `sh tools/shade/hdrcheck/run.sh`. The in-game smoke test used an isolated offline Minecraft 26.3/Fabric 0.19.5 profile, checking mixin application, menu rendering, resize, VSync off/on and graceful shutdown. Offline authentication/Realms errors are unrelated to rendering.

The hotkey build was also exercised in an isolated superflat world with Metal API validation: unassigned defaults, translated Controls labels without Fabric API, assignment save/load, Full scene/Highlights switching, repeated live ProMotion toggles, chat suppression, VSync changes, resizing, and saved preferences after restarting. This exposed two existing terrain-validation issues: disabled exact-culling arguments had no buffers, and the disabled TUnit buffers were smaller than one element. Both now have valid bindings/sizes without enabling those optional paths.

The `promotion.3` handoff correction follows a macOS 27.0.1 WindowServer watchdog report after switching ProMotion off. The report records 40 seconds without a successful display-service check-in; Minecraft's render-thread frame resolves to `-[_MTLCommandBuffer waitUntilCompleted]`. This confirms a display/GPU stall, but does not identify the initiating command or prove the exact cause. The prior code could invalidate a link while its frames were still in flight; the new lifecycle and delayed-GPU regression cover that race. They do not establish that every external-display or OS-level hang is resolved.

Validation of `promotion.3` on the M4 Pro passed the SDR/HDR native suite (24 deliberately delayed transitions total) and the isolated Minecraft world/restore checks. The gameplay run exercised 37 in-world ProMotion key presses, VSync and HDR changes, and repeated resizing; logs recorded 19 deferred GPU handoffs and no Metal validation failures. A stable 120 Hz interval reported 8.38 ms average / 8.50 ms p95, with zero GPU errors. This is a regression check, not a performance comparison with the previous build; the reported WindowServer hang itself was not reproduced.

Still needs real-world testing: sustained gameplay on the external Studio Display XDR, fullscreen transitions, moving the game between displays, sleep/wake, and heavily GPU-bound worlds. Lower input latency is a goal to measure, not a result claimed by this prototype.

API references: [window display links](https://developer.apple.com/documentation/appkit/nswindow/displaylink%28target%3Aselector%3A%29), [CADisplayLink rate requests](https://developer.apple.com/documentation/quartzcore/cadisplaylink/preferredframeraterange). Earlier implementation: [CAMetalDisplayLink](https://developer.apple.com/documentation/quartzcore/cametaldisplaylink), [targetTimestamp](https://developer.apple.com/documentation/quartzcore/cametaldisplaylink/update/targettimestamp), [preferredFrameLatency](https://developer.apple.com/documentation/quartzcore/cametaldisplaylink/preferredframelatency).

## Diagnostic recorder (`promotion.4-diagnostic`)

The second reported whole-desktop freeze still occurred with `promotion.3`. Its log ended at an enable request in exclusive fullscreen on the built-in 120 Hz display. No new WindowServer stack survived. `promotion.4-diagnostic` added evidence collection without changing the display-link handoff. The recorder remains enabled in `promotion.5-diagnostic`.

The recorder is on by default in this diagnostic build. Every launch creates a separate `logs/mcopt-presentation-<time>-<pid>.log` inside the Minecraft game directory; old files are never overwritten. The file records the build, requested/actual pacing state, SDL fullscreen flags, output dimensions, display rate, HDR layer format, creation/invalidation, layer changes, shutdown and shortcut requests. It does not record account credentials, chat, or world contents. Files are created with owner-only permissions.

Transition records use macOS `F_FULLFSYNC` to request persistence before continuing. If that fails, the recorder falls back to `fsync` and records a warning. Ordinary frame markers stay in a bounded memory ring, also dumped when a link closes (including callback-timeout fallback). An independent thread dumps and flushes the last 128 markers after a second without progress, including command-buffer waits, acquisition, commit and present. That monitor makes no Metal or AppKit calls, and does not kill the game. Loading, pausing in a debugger, and shutdown may legitimately trigger a `STALL` record; it is evidence of missing CPU progress, not proof of a GPU hang. A system-wide lockup can still prevent the monitor or storage from making progress.

`-Dmcopt.metal.displayLink.trace=false` disables the recorder. Storage flushes change transition timing, so do not use this diagnostic build's toggle latency as a performance measurement. [Apple's fsync documentation](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/fsync.2.html) explains the additional storage flush.

Recorder regression, without touching the display:

```sh
clang -fno-objc-arc -O2 -Wall -Werror -mmacosx-version-min=15.0 \
  -I metal/src/main/native -framework Foundation -framework QuartzCore \
  metal/src/main/native/mcpresentationtrace.m tools/presentation/tracecheck.m -o /tmp/mcopt-tracecheck
python3 tools/presentation/tracecheck.py /tmp/mcopt-tracecheck
```

The check covers a stalled main thread, ring wraparound, `SIGKILL`, preserving existing files, permissions, open failures and disabled recording. It checks abrupt process termination, not a physical power failure.

Fullscreen regression uses a disposable offline Fabric world and the locally cached Prism dependencies. It never edits an existing Prism instance. Set `JAVA_HOME` to JDK 25, or pass `--java-home`. The baseline leaves ProMotion off; add `--toggle` for a single enable/disable cycle after HDR fullscreen is confirmed:

```sh
python3 tools/presentation/fullscreen-smoke.py /absolute/path/to/mod.jar --output /tmp/mcopt-fullscreen-baseline
python3 tools/presentation/fullscreen-smoke.py /absolute/path/to/mod.jar --output /tmp/mcopt-fullscreen-toggle --toggle
```

The helper sets VSync/120 FPS, requests macOS native fullscreen (Spaces) and 2160p output, verifies the SDL fullscreen mode, checks HDR, then returns to windowed mode. The native toggle test also requires `fullscreenStyle=1` in the captured AppKit layer context; an exclusive test does not count as native-fullscreen coverage. Use `--mode exclusive` to select the earlier test mode, or `--prepare-only` to compile the helper without launching the game. During the live comparison, a render-thread timeout halts **only the temporary game process**. This cannot guarantee recovery from a WindowServer or GPU hang; there is no automatic retry. `game-path` and `fullscreen.log` in the chosen output directory locate the session and its diagnostics, including failed runs.

Fullscreen Metal validation also exposed a separate pre-existing issue before ProMotion was enabled: switching to a terrain configuration without unit occlusion left compute arguments 13–15 unbound. They now receive inert fallback bindings, following the existing disabled-argument pattern. The shader's unit-occlusion flag still controls access; rendering algorithms and enabled culling modes are unchanged.

Validation of `promotion.4-diagnostic` on the M4 Pro / macOS 27.0.1: the no-GPU recorder tests passed. The HDR exclusive-fullscreen baseline passed at 3342×2160 with ProMotion off after the disabled-buffer correction. The single live-enable attempt failed to sustain callbacks: status changed `ACTIVE → WAITING → SWITCHING → FALLBACK` within roughly 0.23 seconds; `inFlight=0` at teardown and invalidation/transaction flush both returned. The test exited with its failure code before the planned explicit toggle-off. The desktop remained responsive. This is a captured fullscreen presentation failure, **not** a reproduction or explanation of the earlier WindowServer freeze; no fullscreen retry was performed.

The final recorder also passed the windowed native SDR/HDR suite with Metal validation and logging enabled: 1,560 callbacks per format, 120/60/90 FPS caps, pixel checks, resize/hide/restore, and 24 delayed-GPU transitions. No storage-sync warnings were recorded.

## Fullscreen handoff (`promotion.5-diagnostic`)

The October 19 user trace captured a different fullscreen path: SDL non-exclusive fullscreen and AppKit `fullscreenStyle=1`, at 3444×2160 HDR. Repeated windowed toggles worked. Turning ProMotion off in native fullscreen left submitted display-link frames outstanding, and the render thread stopped in its ordinary GPU fence before link invalidation began.

Retirement previously stopped calling `begin()`, the only place that serviced the link's private run loop. Rendering continued until the frame limiter or a resource fence called `waitUntilCompleted`. This could stop callback delivery indefinitely. Apple's [run-loop registration documentation](https://developer.apple.com/documentation/quartzcore/cametaldisplaylink/add(to:formode:)) specifies that callbacks are delivered while the registered mode runs. The trace identifies the stalled fence, but does not prove that callback starvation was the sole cause of the WindowServer freeze.

This candidate services that mode during close polling and GPU fences. Registration is tracked per thread until invalidation, independently of the enabled preference. Callbacks during a fence discard unused updates; they do not acquire another frame or run game input. GPU completion and completion-handler ordering still precede recycling resources. The same wait handles buffer uploads, shader/cloud setup, capture readbacks and legacy queue draining. Threads with no display link keep the ordinary Metal wait.

The recorder adds GPU-wait begin/end/status markers. A GPU wait lasting a second writes its own snapshot even if display callbacks keep arriving, then reports every five seconds. This preserves evidence without a busy loop or per-frame disk writes. The change does not add a timeout that releases unfinished GPU resources, and cannot recover an arbitrary driver or WindowServer hang.

The windowed regression now makes a real GPU frame depend on work scheduled in the private display-link mode. It checks an active link, a retiring link and close polling alone. A background watchdog releases the synthetic GPU gate if the test regresses. The previous build fails this test; the candidate passes in SDR and HDR, along with the existing presentation/pixel/resize and 24 delayed-GPU transition checks. Native fullscreen has not been rerun for this candidate; that specific system-freeze correction remains unconfirmed.

An isolated Minecraft/Fabric world also passed three windowed HDR on/off cycles and shutdown with ProMotion active, with Metal API validation enabled. This check changes the live preference directly, so menus cannot suppress a synthetic hotkey. An earlier hotkey check stopped at an open pause menu; an unfocused handoff attempt lost display callbacks and fell back without freezing. The successful run explicitly raised the temporary window and verified focus before testing. These results establish windowed behavior, not fullscreen stability or a latency improvement.

## Windowed cadence comparison (October 20)

`pacing-bench.py` measures both presentation paths in the same disposable offline Fabric world. It leaves the renderer unchanged and adds a test-only timestamp immediately after SDL input polling. `GpuTimes` supplies GPU and Metal presentation timestamps for both paths. The benchmark does not change the user's Prism profile, launch fullscreen, or enable Metal API validation.

Leave its window focused until it exits (about four minutes). Minecraft's AFK throttle is disabled only in the temporary profile; every measured frame records the actual FPS cap, pacing state, focus and fullscreen flags. The test runs 50 FPS in Off/On/On/Off order, followed by 60 On/Off and 120 Off/On, then another 120 FPS Off/On/On/Off comparison under varying GPU load. Each phase excludes four seconds of settling and measures twelve seconds. Transition diagnostics remain enabled, so this does not measure toggle latency.

The load helper adds compute work to presenting command buffers in both modes: four sustained work levels, changing every 24 frames, plus a burst every eleven frames. This deliberately makes actual delivery vary below the 120 FPS cap. It measures behavior under synthetic GPU contention, not performance in a representative complex world. The helper is compiled into the disposable test profile and is never packaged in the mod JAR.

```sh
python3 tools/presentation/pacing-bench.py /absolute/path/to/mod.jar \
  --java-home /absolute/path/to/jdk25 --output /tmp/mcopt-pacing-comparison
python3 tools/presentation/pacing-analyze.py /tmp/mcopt-pacing-comparison/measurements.json
```

The output directory must be new. `--prepare-only` compiles the helper without launching. The runner records the JAR checksum and launch arguments; the analyzer reports timestamp coverage and rejects invalid comparisons. Presentation intervals use unique Metal `presentedTime` values within each measured phase, not GPU completion or callback-delivery times. Poll-to-presentation measures the software pipeline, not physical input-to-photon latency. A focused window and `Active` status do not prove a particular physical panel refresh rate.

Historical baseline (eight phases, fifteen-second samples, no added GPU load): M4 Pro's built-in 120 Hz display, macOS 27.0.1, full-scene HDR at 1280×800, VSync on, with `promotion.5-diagnostic` (`e318ee7`):

| Cap | Off: interval p95 | On: interval p95 | Off: median poll-to-presentation | On: median poll-to-presentation |
| --- | ---: | ---: | ---: | ---: |
| 50 FPS, repeated | 25.00 ms | 33.33 ms | 29.32–29.80 ms | 49.79–49.83 ms |
| 60 FPS | 16.67 ms | 16.67 ms | 30.19 ms | 49.79 ms |
| 120 FPS | 8.33 ms | 8.33 ms | 30.24 ms | 41.52 ms |

All eight measured phases retained focus, the requested cap and the expected pacing state. No measured presentation timestamps were missing or duplicated; no GPU recorder slots were dropped. Clock-calibration offset changed by 42 ns. An earlier preparation had a test-only mixin packaging error; subsequent preliminary runs were discarded for AFK throttling and focus loss.

At 50 FPS, On averaged almost exactly 50 frames per second but alternated 16.67 and 33.33 ms intervals (about 80%/20%). Off predominantly used 16.67 and 25 ms. This is consistent with On selecting frames from a 60 Hz schedule while Off uses finer presentation opportunities. It does not directly measure the callback frequency or panel refresh rate. Apple's rate request is a preference; the OS can round it. The current deadline grid preserves an average cap without guaranteeing evenly spaced frames.

At 60 and 120 FPS, On eliminated the occasional short/long intervals seen with Off in this sample, but increased the software latency estimate by about 20 and 11 ms respectively. These measurements do not demonstrate an overall user improvement. Investigate rate rounding and the additional presentation delay before recommending the feature. This is a light, static scene with short samples, not a GPU-saturation, external-display, fullscreen or physical-latency benchmark.

## Callback-only experiment (`promotion.7-diagnostic`)

This is an experimental checkpoint, not a recommended pacing upgrade. VSync remains enabled and the feature remains opt-in. HDR, the sun-haze correction and the existing GPU-fence lifecycle protections are retained.

A focused native probe isolated a source of delay in the original path on this machine: `CAMetalDisplayLink` drawable targets were 33.33 ms later than their CPU submission deadlines, even when rendering finished much earlier. Requesting 120 Hz callbacks, explicitly flushing transactions, and polling input later did not remove that gap. A callback-only `CADisplayLink` with ordinary layer drawables avoided the imposed presentation target. This is an observation on this OS/display combination, not a general latency guarantee for either API.

The first callback-only candidate (`promotion.6`) forced two drawables. In Minecraft this reduced normal 120 FPS delivery to about 80 FPS, so that restriction was removed. `promotion.7` preserves the configured drawable pool, requests the screen's maximum callback rate, and acquires a drawable before input polling.

Revised Minecraft test: same built-in display, windowed HDR at 1280×800, VSync on; twelve phases with four seconds settling and twelve seconds measurement each. JAR SHA-256: `9ce3293d86579923bfe9712dae2eb29beb9334ca0ab67d1d9e6f6c525a6eabd6`.

| Case | Off → On displayed FPS | Off → On interval p95 | Off → On median poll-to-presentation |
| --- | ---: | ---: | ---: |
| 50 FPS, repeated | 49.91–49.94 → 50.01–50.06 | 25.00 → 33.33 ms | 28.22–28.49 → 24.87 ms |
| 60 FPS | 59.88 → 59.94 | 16.67 → 25.00 ms | 29.72 → 24.90 ms |
| 120 FPS, light scene | 119.50 → 119.92 | 8.33 → 8.33 ms | 29.93 → 32.51 ms |
| 120 FPS, varying GPU load, repeated* | 99.74–100.05 → 94.90–95.03 | 16.67 → 16.67 ms | 41.44–41.73 → 32.53–32.54 ms |

All twelve phases retained focus, windowed HDR, the requested cap and the expected pacing state. No recorder slots were dropped; clock-offset drift was 42 ns. The eight light-scene phases and the two loaded On phases had complete, unique presentation timestamps. At light 120 FPS, interval standard deviation improved from 0.54 to 0.22 ms, but median software latency increased by 2.58 ms.

*The loaded Off phases lacked both callback and presentation timestamps for 26/1,228 and 21/1,221 submitted frames. The table reports observed presentation timestamps only. The recorder reads native slots at the final report, rather than copying them at GPU retirement, and waits another second after the final phase; this is not explained by copying timestamps immediately at command completion. Dropped presentations are a possibility, but the available evidence cannot distinguish that from missing notifications. The analyzer correctly rejects these two phases as fully validated comparisons. Loaded On had no missing timestamps. Its interval standard deviation was about 3.99 ms versus 3.48–3.54 ms for the observed baseline frames.

The build and windowed native Metal validation passed: SDR/HDR pixels, 1,560 frames per format, resize/hide/restore, twelve delayed-GPU transitions per format, and run-loop-dependent completion during active/retiring/close states. The Minecraft run exited normally with no pacing GPU errors. Fullscreen was not tested.

This experiment removes much of the old path's latency penalty, but does not meet all three goals together. Lower caps have worse frame spacing; the loaded comparison suggests a throughput tradeoff; light 120 FPS has higher median software latency. These tests neither measure physical input-to-photon latency nor prove tear-free scanout or physical VRR.

Next investigation: schedule work to finish before a presentation opportunity, using measured CPU/GPU cost, instead of always starting on a callback. In the 60 FPS On sample, frames shown about 25 ms after input had a median input-to-GPU-finish time of 6.59 ms, while the 33 ms group took 9.29 ms. That correlation is consistent with straddling an 8.33 ms presentation boundary. Also examine avoidable callback waits when rendering is already below the cap, and resolve missing baseline presentation notifications before claiming an under-load improvement.


## Render-budget experiment (`promotion.8-diagnostic`)

This candidate uses measured rendering cost to schedule work before a display opportunity, and bypasses the extra callback wait when already below the requested FPS. Drawable acquisition still precedes input, VSync stays enabled, and the configured drawable pool is preserved. It does not request a future presentation timestamp or wait for presentation callbacks. The existing run-loop/GPU retirement protections remain in place. A fresh callback is required after a rate change or pause; stale callbacks have the same bounded fallback as before.

The trace now records the screen's minimum/maximum refresh intervals and update granularity, and the periodic report includes the learned rendering budget and how many frames bypassed an extra clock wait. These describe OS capabilities and scheduling decisions, not proof of physical VRR or input-to-photon latency.

Headless policy regression (no window or focus needed):

```sh
clang -O2 -Wall -Wextra -Werror -I metal/src/main/native \
  tools/presentation/pacingcheck.c -o /tmp/mcopt-pacingcheck
/tmp/mcopt-pacingcheck
```

It exercises average caps at 50/60/90/120 FPS, changing work duration, stalls, refresh changes, invalid samples and reset behavior. Hardware comparisons are still needed before claiming an improvement.

### Context from other implementations

- [Unity’s macOS implementation and 6000.3.11f1 backport](https://discussions.unity.com/t/stuttering-in-2023-2-and-6000-0-in-a-minimal-urp-project-on-macos/1525359?page=3) added opt-in macOS CAMetalDisplayLink support for more consistent pacing. That establishes an engine precedent, not a latency guarantee for this integration.
- [DXMT's configuration](https://github.com/3Shain/dxmt/blob/main/docs/CUSTOMIZATION.md) recommends preferred frame rates that divide the display rate. Its [default configuration notes](https://github.com/3Shain/dxmt/blob/main/dxmt.conf) warn that macOS can round a requested rate; a 40 FPS request on a 60 Hz screen can yield 30. Our 50 FPS test deliberately checks a non-divisor.
- [SDL's macOS latency investigation](https://github.com/libsdl-org/SDL/issues/14456) identifies input sampled before blocking drawable acquisition as a source of latency and explores scheduling from display timing and rendering cost. This is an ongoing investigation, not a validated drop-in fix.
- [Apple's variable-refresh presentation guidance](https://developer.apple.com/videos/play/wwdc2021/10147/) uses measured GPU duration to adapt presentation and distinguishes fixed from variable refresh through screen timing properties. Its external Adaptive Sync guidance requires fullscreen; our windowed comparisons cannot establish that behavior.
- [Filament's FrameSkipper](https://github.com/google/filament/blob/main/filament/src/FrameSkipper.cpp) separately limits queued GPU work with fences. This is distinct from timing a frame's start. Our earlier two-drawable experiment reduced throughput, so we preserve the normal pool while investigating scheduling.
- [MoltenVK's swapchain implementation](https://github.com/KhronosGroup/MoltenVK/blob/main/MoltenVK/MoltenVK/GPUObjects/MVKSwapchain.mm) documents missing final Metal presentation notifications. That warrants investigating our missing baseline timestamps, but does not establish the same cause. Its destruction workaround is not applied to live Minecraft frames.


### Windowed results, October 20

`promotion.8` passed the headless timing checks and the focused native Metal validation: SDR/HDR pixels, caps, resize/hide/restore, run-loop-dependent GPU completion and 24 delayed/uncommitted transitions. Minecraft completed all twelve phases without a freeze, with focus, VSync, windowed HDR, requested caps and expected pacing states verified. The recorder dropped no slots; clock offset changed by 104 ns. The JAR contains no benchmark helper. SHA-256: `e430ec1db0a705c117102ea1923f63522ce19e60055fbf8b3409e36189a73564`.

| Case | Off → On displayed FPS | Off → On interval p95 | Off → On median poll-to-presentation |
| --- | ---: | ---: | ---: |
| 50 FPS, repeated | 49.84 → 49.97–50.01 | 25.00 → 33.33 ms | 29.37–29.84 → 27.60–27.70 ms |
| 60 FPS | 59.83 → 60.00 | 16.67 → 25.00 ms | 29.73 → 27.18 ms |
| 120 FPS, light | 119.33 → 115.74 | 8.33 → 8.33 ms | 29.46 → 28.93 ms |
| 120 FPS, varying GPU load, repeated* | 97.72–99.92 → 91.89–93.28 | 16.67 → 16.67 ms | 41.57–43.18 → 32.06–32.08 ms |

*The loaded Off phases again lacked presentation notifications (25/1,225 and 41/1,216 submitted frames); reported FPS and latency use observed timestamps and are not a fully valid comparison. The analyzer rejects those phases. All On phases had complete, unique timestamps. Interval standard deviation at light 120 FPS worsened from 0.62 to 1.57 ms; loaded On measured 3.99–4.16 ms versus 3.49–3.72 ms for the observed baseline frames.

**Do not recommend this candidate as an upgrade.** It exchanges a little software latency for worse pacing at lower caps and lower throughput at 120 FPS. The budget was active: about 11–12 ms at lower caps and 18–23 ms under load; loaded frames almost entirely bypassed the extra display-clock alignment. Eliminating that wait did not resolve the throughput tradeoff.

The built-in screen reported minimum/maximum intervals of 8.333/41.667 ms (120/24 Hz) and update granularity of 4.167 ms. The observed callback interval remained 8.333 ms. These are OS capability and callback measurements, not proof of the panel's instantaneous refresh or a G-Sync-equivalent presentation path. VSync stayed enabled, but tearing and physical input latency were not measured. Fullscreen was not tested.

Next investigation should isolate presentation/backpressure from the render-start clock, and account for the missing baseline notifications before making an under-load claim. A fixed phase offset from a display callback and a recent rendering budget are insufficient to predict this compositor's presentation decisions. Actual presentation feedback may help; the present callback cannot become an unbounded gate because notification coverage is incomplete.
