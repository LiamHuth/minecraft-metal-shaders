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

Optional:

- `-Dmcopt.metal.displayLink.latency=2`: request Apple's two-frame GPU budget instead of one. May help a heavy workload but can increase latency.
- `-Dmcopt.metal.displayLink.log=false`: disable the periodic native pacing report.

## Behavior

The game waits for `CAMetalDisplayLink` before SDL input polling. The link supplies the drawable; this path never calls `nextDrawable`. The normal HDR/SDR presentation shaders draw directly into it. After committing the frame, the drawable is presented before the update's CPU deadline when possible. This avoids the separate staging/presentation queue and the old after-render pacer in this mode.

The preferred rate follows the window's display maximum and the game's current cap. A timestamp grid enforces the average cap if the OS rounds a request upward (observed with 90 requested on a 120 Hz panel). Minecraft's own lower menu cap still applies. The ordinary limiter remains available if the cap drops mid-frame. Caps below 30, minimization, and VSync off return to the legacy path.

Lifecycle, callbacks and rendering stay on the game thread. A private run-loop mode also runs Core Animation's common-mode observers, so layer transactions continue to reach the compositor. Disabling, resizing, and fallback first retire the link: stop acquiring frames, keep every encoded drawable and its command buffer alive, and poll completion at frame boundaries. This includes frames encoded but not yet committed. Until completion, presentation is skipped and the layer remains unchanged. Only then is the link paused, invalidated exactly once and released, and the Core Animation transaction flushed before ordinary drawable acquisition resumes. Pending resize/VSync configurations are coalesced during retirement. Close attempts service the private run-loop mode with a 1 ms budget before checking completion again. Renderer GPU fences also service that mode while a link remains registered, including during retirement and shutdown. Merely pausing is insufficient for changing `maximumDrawableCount`. Legacy presentation is drained before the link takes over acquisition. Callback waits are bounded to 50 ms; three consecutive timeouts request a return to the legacy path with a later retry.

## Measurements and validation

The native report appears in Prism's console/stderr every 10 seconds while the link remains active. It includes the requested rate, valid presentation timestamps, average and p95 display intervals, callback-to-display time, late CPU commits, missing drawables/timestamps, and GPU errors. P95 uses 0.5 ms histogram bins (values above 127.5 ms share the final bin). Missing timestamps are counted separately; they are not treated as successful measurements. Callback-to-display is **not** a measurement of physical input-to-photon latency. Windowed macOS compositing may add buffering despite a one-frame preference.

Existing `mcopt.metal.gpuTimes` / `mcopt.own.int.frameLog` instrumentation works with both paths, including the provided drawable's presentation timestamp. Compare stable runs at the same window size, HDR mode, scene, FPS cap and power settings. Exclude startup, shader compilation, resize and other transitions. Compare displayed-frame intervals and hitches, rather than relying on the rendered FPS counter.

Build first, then run `sh tools/presentation/run.sh [output-directory] [latency:1|2]`. This opens a temporary test window and uses the actual native backend with Metal API validation. It exercises SDR and full-scene HDR pixels above SDR white, sustained 120 Hz requests, 60/90 FPS caps, a missed deadline, resizing, hide/restore, and teardown/recreation. For each output format it also performs twelve transitions with a command buffer deliberately held by a CPU-signalled Metal shared event. Closing must defer both before commit and while the GPU is waiting, and ordinary presentation must work after releasing the event. An unused acquired drawable is checked separately. Completion checks are bounded, so a regression fails the harness rather than waiting forever. The scene is deliberately tiny: it tests presentation and does not establish Minecraft performance gains.

Also run `sh tools/shade/hazecheck/run.sh` and `sh tools/shade/hdrcheck/run.sh`. The in-game smoke test used an isolated offline Minecraft 26.3/Fabric 0.19.5 profile, checking mixin application, menu rendering, resize, VSync off/on and graceful shutdown. Offline authentication/Realms errors are unrelated to rendering.

The hotkey build was also exercised in an isolated superflat world with Metal API validation: unassigned defaults, translated Controls labels without Fabric API, assignment save/load, Full scene/Highlights switching, repeated live ProMotion toggles, chat suppression, VSync changes, resizing, and saved preferences after restarting. This exposed two existing terrain-validation issues: disabled exact-culling arguments had no buffers, and the disabled TUnit buffers were smaller than one element. Both now have valid bindings/sizes without enabling those optional paths.

The `promotion.3` handoff correction follows a macOS 27.0.1 WindowServer watchdog report after switching ProMotion off. The report records 40 seconds without a successful display-service check-in; Minecraft's render-thread frame resolves to `-[_MTLCommandBuffer waitUntilCompleted]`. This confirms a display/GPU stall, but does not identify the initiating command or prove the exact cause. The prior code could invalidate a link while its frames were still in flight; the new lifecycle and delayed-GPU regression cover that race. They do not establish that every external-display or OS-level hang is resolved.

Validation of `promotion.3` on the M4 Pro passed the SDR/HDR native suite (24 deliberately delayed transitions total) and the isolated Minecraft world/restore checks. The gameplay run exercised 37 in-world ProMotion key presses, VSync and HDR changes, and repeated resizing; logs recorded 19 deferred GPU handoffs and no Metal validation failures. A stable 120 Hz interval reported 8.38 ms average / 8.50 ms p95, with zero GPU errors. This is a regression check, not a performance comparison with the previous build; the reported WindowServer hang itself was not reproduced.

Still needs real-world testing: sustained gameplay on the external Studio Display XDR, fullscreen transitions, moving the game between displays, sleep/wake, and heavily GPU-bound worlds. Lower input latency is a goal to measure, not a result claimed by this prototype.

API references: [CAMetalDisplayLink](https://developer.apple.com/documentation/quartzcore/cametaldisplaylink), [targetTimestamp](https://developer.apple.com/documentation/quartzcore/cametaldisplaylink/update/targettimestamp), [preferredFrameLatency](https://developer.apple.com/documentation/quartzcore/cametaldisplaylink/preferredframelatency).

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

Leave its window focused until it exits (about three minutes). Minecraft's AFK throttle is disabled only in the temporary profile; every measured frame records the actual FPS cap, pacing state, focus and fullscreen flags. The test runs 50 FPS in Off/On/On/Off order, followed by 60 On/Off and 120 Off/On. Each phase excludes four seconds of settling and measures fifteen seconds. Transition diagnostics remain enabled, so this does not measure toggle latency.

```sh
python3 tools/presentation/pacing-bench.py /absolute/path/to/mod.jar \
  --java-home /absolute/path/to/jdk25 --output /tmp/mcopt-pacing-comparison
python3 tools/presentation/pacing-analyze.py /tmp/mcopt-pacing-comparison/measurements.json
```

The output directory must be new. `--prepare-only` compiles the helper without launching. The runner records the JAR checksum and launch arguments; the analyzer reports timestamp coverage and rejects invalid comparisons. Presentation intervals use unique Metal `presentedTime` values within each measured phase, not GPU completion or callback-delivery times. Poll-to-presentation measures the software pipeline, not physical input-to-photon latency. A focused window and `Active` status do not prove a particular physical panel refresh rate.

Observed on the M4 Pro's built-in 120 Hz display, macOS 27.0.1, full-scene HDR at 1280×800, VSync on, with `promotion.5-diagnostic` (`e318ee7`):

| Cap | Off: interval p95 | On: interval p95 | Off: median poll-to-presentation | On: median poll-to-presentation |
| --- | ---: | ---: | ---: | ---: |
| 50 FPS, repeated | 25.00 ms | 33.33 ms | 29.32–29.80 ms | 49.79–49.83 ms |
| 60 FPS | 16.67 ms | 16.67 ms | 30.19 ms | 49.79 ms |
| 120 FPS | 8.33 ms | 8.33 ms | 30.24 ms | 41.52 ms |

All eight measured phases retained focus, the requested cap and the expected pacing state. No measured presentation timestamps were missing or duplicated; no GPU recorder slots were dropped. Clock-calibration offset changed by 42 ns. An earlier preparation had a test-only mixin packaging error; subsequent preliminary runs were discarded for AFK throttling and focus loss.

At 50 FPS, On averaged almost exactly 50 frames per second but alternated 16.67 and 33.33 ms intervals (about 80%/20%). Off predominantly used 16.67 and 25 ms. This is consistent with On selecting frames from a 60 Hz schedule while Off uses finer presentation opportunities. It does not directly measure the callback frequency or panel refresh rate. Apple's rate request is a preference; the OS can round it. The current deadline grid preserves an average cap without guaranteeing evenly spaced frames.

At 60 and 120 FPS, On eliminated the occasional short/long intervals seen with Off in this sample, but increased the software latency estimate by about 20 and 11 ms respectively. These measurements do not demonstrate an overall user improvement. Investigate rate rounding and the additional presentation delay before recommending the feature. This is a light, static scene with short samples, not a GPU-saturation, external-display, fullscreen or physical-latency benchmark.
