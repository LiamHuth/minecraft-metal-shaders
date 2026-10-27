# ProMotion frame pacing experiments and reference

Prepared 25 October 2026 for [minecraft-metal-shaders issue 11](https://github.com/GaelQuinta/minecraft-metal-shaders/issues/11). Measurements discussed here were collected during the October 2026 investigation, through 24 October.

The objective was less tearing and more consistent frame delivery without increasing input latency, especially below 120 FPS under varying GPU load. None of the tested implementations consistently met all three goals. One change improved frame freshness when rendering substantially faster than the display, but did not address low-FPS smoothness. These results describe particular implementations on one setup; they do not establish that ProMotion or Metal cannot support a better result.

The experiments are paused and checkpointed. The latest options remain disabled by default. This reference preserves the detailed results behind the shorter issue comment. Published with the experimental source on 27 October 2026; see the [contributor handoff](../../PROMOTION_HANDOFF.md) for branch links, build instructions, and current testing precautions.

## Setup and scope

- Primary hardware: 16-inch MacBook Pro, M4 Pro, built-in 120 Hz Retina display.
- Software: macOS 27.0.1, Minecraft 26.3, Fabric Loader 0.19.5, Java 25.0.1 and LWJGL 3.4.3.
- Initial base: `v1.2.5-alpha` at `a5b5a98`. Later experiments restarted from upstream main at `cc35628`, dated 23 October, without the earlier display-link scheduler.
- Latest tested code checkpoint: branch `feat/promotion-lowfps-schedule`, commit `0233045`. The source and earlier experimental history are now published in [LiamHuth/minecraft-metal-shaders](https://github.com/LiamHuth/minecraft-metal-shaders); the handoff identifies both branches. Documentation-only publication commits do not change these tested implementations.
- Most later comparisons: native macOS fullscreen, full-scene HDR, VSync, three drawables and 1434×900 output. Windowed, SDR and native 3456×2168 output checks were separate comparisons.
- The external display configuration in the original issue was not validated. Results from the built-in panel should not be generalized to it.

Native Metal probes isolated presentation behavior. Minecraft tests used disposable offline profiles and flat worlds, fixed cameras, frozen time/weather and disabled mob spawning. Synthetic GPU work created controlled periods below the FPS cap. These are not measurements of chunk loading, garbage collection or representative complex-world gameplay.

## Measurement definitions

Software delay means time from input polling to Metal's reported `presentedTime`. The native probe instead measured from render start after its pre-frame wait/acquisition; it did not poll Minecraft input. Neither measures physical input-to-photon latency.

Presentation intervals use unique `presentedTime` values, not callback arrival times or GPU completion timestamps. Frame-spacing standard deviation describes variation in those intervals. Frame age and the gap between displayed frames are different measurements: a 90 ms input-to-presentation age does not imply a 90 ms display freeze.

Presentation timestamps, callback rates and reported display capabilities do not prove physical VRR or the absence of tearing. Visual observations are identified separately below.

Later comparisons used separate control/candidate/candidate/control processes, identical binary and harness hashes, warmup, settling periods and 10- or 20-second measurement windows. The reported later averages are means of per-session statistics from two sessions per mode, not thousands of independent observations. Earlier short probes had weaker controls and are labeled accordingly. Results from different prototypes and protocols must not be combined as one continuous benchmark.

## Direct CAMetalDisplayLink integration

The initial implementation used drawables and targets supplied by `CAMetalDisplayLink`. A focused native probe found presentation targets approximately 33.33 ms later than their CPU submission deadlines, even when GPU rendering finished much earlier. Requesting 120 Hz, explicitly flushing transactions and moving input polling later did not remove the gap on this OS/display combination.

An early windowed HDR comparison at 1280×800 measured:

| Cap | Control interval p95 | Candidate interval p95 | Control median software delay | Candidate median software delay |
|---|---:|---:|---:|---:|
| 50 FPS, repeated | 25.00 ms | 33.33 ms | 29.32–29.80 ms | 49.79–49.83 ms |
| 60 FPS | 16.67 ms | 16.67 ms | 30.19 ms | 49.79 ms |
| 120 FPS | 8.33 ms | 8.33 ms | 30.24 ms | 41.52 ms |

These eight light-scene phases retained focus and had complete, unique presentation timestamps. At 50 FPS the candidate maintained approximately the desired average while alternating 16.67 and 33.33 ms intervals. Average FPS therefore concealed poor cadence. The result did not establish a particular physical panel refresh rate.

## Display callbacks used only as a clock

A subsequent implementation used an `NSWindow`-associated `CADisplayLink` for timing, ordinary layer drawables and ordinary `presentDrawable:`. Blocking drawable acquisition preceded input polling. It requested the screen's maximum callback rate independently of the game's FPS cap and scheduled against observed callback intervals.

This removed much of the original delay penalty. It did not establish a consistently better tradeoff. At light 120 FPS, one comparison reduced interval standard deviation from 0.54 to 0.22 ms while adding 2.58 ms of median delay. Lower caps had worse spacing. Some loaded baseline phases lacked presentation notifications, so their apparent throughput/latency differences were not accepted as fully validated comparisons.

An early two-drawable variant reduced normal 120 FPS delivery to approximately 80 FPS and was rejected. Later variants preserved the existing drawable pool.

Requested callback rates were not reliable substitutes for observed rates. A 50 FPS request could be serviced on a coarser schedule; selecting frames from 60 Hz callbacks produced uneven timing. Requesting maximum-rate callbacks gave finer scheduling opportunities, but did not by itself provide arbitrary presentation intervals.

## Scheduling rendering ahead of a display opportunity

Another candidate estimated rendering cost from recent p90 CPU/GPU elapsed time, with a small margin and an estimate that rose quickly and fell gradually. It attempted to start rendering early enough for the next presentation opportunity. It skipped the extra callback wait when the frame had already consumed the cap period.

In windowed tests, the candidate maintained approximately 50 and 60 FPS but worsened interval p95 from 25.00 to 33.33 ms at 50 FPS and from 16.67 to 25.00 ms at 60 FPS. Light 120 FPS delivery fell from 119.33 to 115.74 FPS, with interval standard deviation increasing from 0.62 to 1.57 ms.

The learned budget was active, approximately 11–12 ms at lower caps and 18–23 ms under load. Loaded frames mostly bypassed the additional callback alignment, but the throughput/cadence tradeoff remained. A fixed phase offset plus a recent rendering budget did not reliably predict the system's presentation decisions.

## Minimum duration and queue control

The next matrix separated CPU timing from `presentDrawable:afterMinimumDuration:` and independently varied pending-frame limits. An adaptive variant used a smoothed GPU duration with a margin. Tests preserved VSync and the configured three-drawable pool; pending-frame limits were a separate policy.

Representative windowed Minecraft results:

| Case | Displayed FPS | Interval p95 | Median software delay |
|---|---:|---:|---:|
| 50 cap, existing renderer | 49.94 | 25.00 ms | 28.71 ms |
| 50 cap, minimum duration | 40.00 | 25.00 ms | 65.72 ms |
| 60 cap, existing renderer | 59.87 | 16.67 ms | 28.71 ms |
| 60 cap, minimum duration | 60.00 | 16.67 ms | 49.12 ms |
| 60 cap, duration and queue two | 59.94 | 16.67 ms | 32.01 ms |
| 120 cap, existing renderer | 119.50 | 8.33 ms | 30.27 ms |
| 120 cap, duration and queue two | 69.09 | 25.00 ms | 23.73 ms |
| 120 cap, duration and queue three | 108.33 | 16.67 ms | 23.74 ms |

At 50 FPS, minimum-duration presentation held images for 25 ms rather than the requested 20 ms, consistent with rounding up on an 8.33 ms presentation grid. At 60 FPS, interval standard deviation improved from 2.47 ms to approximately zero, but median software delay increased by 20.41 ms. Queue restrictions recovered delay by sacrificing throughput in other cases.

These results show why smoothing a frame-time graph is insufficient evidence of an improvement. The same policy can add buffering or reduce delivered FPS. Some loaded baseline phases had incomplete presentation notification coverage and were excluded as definitive comparisons.

## Windowed and native fullscreen behavior

A small native renderer entered fullscreen before layer creation and kept HDR, VSync and a 1280×800 render target fixed. It completed 24 measured phases with valid focus/timestamps and no reported GPU errors. This was a single fixed-order sweep, one second settling and four seconds measurement per phase, so it is exploratory rather than a robust gameplay benchmark.

| Native probe case | Windowed → fullscreen FPS | Windowed → fullscreen median render-start delay |
|---|---:|---:|
| 50 cap, ordinary presentation | 48.76 → 48.71 | 21.09 → 5.96 ms |
| 50 cap, minimum duration | 39.32 → 48.00 | 65.66 → 41.23 ms |
| 83 cap, minimum duration | 59.87 → 80.00 | 49.05 → 24.65 ms |
| 120 cap, varying load, ordinary presentation | 106.55 → 109.18 | 24.94 → 8.15 ms |
| 120 cap, varying load, minimum duration | 109.90 → 114.47 | 32.42 → 26.15 ms |

Fullscreen exposed 12.50 ms intervals at the 83 FPS duration cap and 20.83 ms intervals at the 50 FPS duration cap. Windowed presentation predominantly used 16.67 and 25 ms respectively. The built-in display reported minimum/maximum intervals of 8.333/41.667 ms and update granularity of 4.167 ms; callbacks remained approximately 8.333 ms apart.

This suggests different scheduling in fullscreen, not proof of physical scanout timing. Even in fullscreen, the duration policy's greater loaded throughput came with substantially more delay than ordinary presentation.

Minecraft already benefited from fullscreen in its unchanged presentation path. In a later repeated fullscreen comparison, ordinary presentation with pre-input cap/acquisition reduced loaded median delay from 25.10 to 20.54–20.91 ms, but reduced displayed FPS from 105.31 to 103.59–103.65 and worsened p95 delay from 38.97 to 43.32–44.42 ms. The fully covered baseline repeat was used; an earlier baseline with a missing notification was excluded.

Light 120 FPS delivery fell from 119.40 to about 115.30 FPS, and interval standard deviation grew from 0.59 to 1.65 ms. Lower caps also undershot. A run-loop wait and anchoring subsequent deadlines after acquisition plausibly explained the persistent cap loss. Reusing the existing precise kernel timer addressed that undershoot, but the whole presentation path still did not establish a consistent benefit. Those comparisons did not isolate the timer as the sole cause of later variation.

## Fresher completed image selection on newer main

This experiment restarted on `cc35628` and kept the existing acquisition worker, VSync, device-local Metal event and drawable pool. It did not use the earlier display-link scheduler.

Normally, the worker selects a staging image before calling `nextDrawable`. If acquisition blocks, a newer image can finish rendering during that wait. The candidate makes one nonblocking attempt to claim a newer GPU-completed image after acquisition. If none is available, it immediately presents the original selection.

Completion handlers publish a monotonic CPU watermark; out-of-order callbacks cannot move it backward. An atomic mailbox claim transfers ownership before metadata is read. Existing GPU ordering and resource fences remain authoritative. Presentation callbacks follow the selected frame's identity, and intentional replacements are distinct from missing measurements.

An initial CPU-readable `MTLSharedEvent` version added roughly 2.6–2.9 ms of median delay in light fullscreen tests and lowered loaded FPS. It was rejected in favor of the completion-handler approach without changing the GPU event type.

One longer fullscreen A/B/B/A set measured:

| Workload | Control / candidate displayed FPS | Control / candidate median software delay |
|---|---:|---:|
| 120 cap, light | 119.53 / 119.50 | 14.92 / 14.64 ms |
| 120 cap, varying GPU load | 106.01 / 106.41 | 31.63 / 30.59 ms |
| 240 cap, light | 120.00 / 120.00 | 39.36 / 30.96 ms |
| 240 cap, varying GPU load | 105.33 / 105.68 | 37.63 / 37.41 ms |

The 240-cap light case made 2,541 actual replacements and preserved 8.33 ms spacing. However, later control medians varied substantially. The final comparison averaged 34.32 versus 29.73 ms median delay and 41.33 versus 33.47 ms p95; a fixed 8 ms improvement was not established across all runs. Staying at 120 FPS still gave lower delay than raising the cap in the light scene.

There were no replacements in the 120-cap samples of the longer set. The final 120-cap varying-load comparison was effectively unchanged: 106.81 versus 106.85 FPS, 30.84 versus 30.57 ms median delay. Native-resolution loaded tests likewise had no replacements and no established benefit: 91.71 versus 90.97 FPS, 33.95 versus 33.03 ms median delay.

A separate prototype only published images after GPU completion. It passed correctness checks but reduced loaded delivery to approximately 94–95 FPS and increased timing spikes. It was rejected. Preserving overlap between rendering and presentation mattered.

Windowed controls also varied between sessions: at 50 FPS, one control median was 16.42 ms and another 29.46 ms. Averaging away that unexplained shift would overstate confidence in a benefit or regression.

## Lower FPS results for completed image selection

Four fullscreen A/B/B/A sessions used 20-second measurements at 30/40/50/60 FPS, then a 60 FPS cap with doubled synthetic GPU work changing every second. The loaded phase delivered periods near 34–35, 45–46 and 58–62 presentations per one-second window; boundary crossings explain counts slightly above 60.

| Workload | FPS control / candidate | Spacing SD control / candidate | Median delay control / candidate | p95 delay control / candidate |
|---|---:|---:|---:|---:|
| 30 cap, light | 29.97 / 29.97 | 3.00 / 2.93 ms | 14.96 / 15.21 ms | 18.52 / 18.66 ms |
| 40 cap, light | 39.94 / 39.93 | 5.07 / 4.76 ms | 14.65 / 14.36 ms | 21.50 / 21.03 ms |
| 50 cap, light | 49.90 / 49.92 | 4.00 / 4.09 ms | 13.65 / 13.76 ms | 18.22 / 18.54 ms |
| 60 cap, light | 59.87 / 59.89 | 3.52 / 3.68 ms | 13.66 / 13.72 ms | 17.14 / 17.64 ms |
| 60 cap, varying load | 54.38 / 54.38 | 5.02 / 5.04 ms | 24.16 / 23.54 ms | 90.53 / 90.59 ms |

No candidate sample replaced a frame. Small differences therefore did not establish that selection improved low-FPS smoothness. Presentation interval p95 was identical between modes in every phase. No measured display gap exceeded 50 ms in this particular matrix; the roughly 90 ms loaded delay tail was frame age.

At light 40 FPS, interval standard deviation grew from 0.06 ms at input polling to 2.50 ms at CPU submission, 2.79 ms at GPU completion and 5.07 ms at presentation. Variation therefore arose both before and after GPU completion. These stages are correlated; their standard deviations cannot be added.

## Input relative presentation deadlines

The latest experiment records a native timestamp immediately after input polling and carries an earliest presentation target with the frame. The worker uses `presentDrawable:atTime:` only when VSync is enabled and the target remains in the future. Expired targets and missing/stale input timestamps use ordinary presentation. It adds no CPU sleep, GPU fence, display link or drawable-pool change.

A 12 ms pilot was followed by an 11 ms budget in four fullscreen A/B/B/A sessions, with 20 seconds per phase. Fresh-image replacement was disabled in both modes to isolate scheduling. All sessions used identical jar/harness hashes, passed focus/settings/coverage checks and closed normally.

| Workload | FPS control / scheduled | Spacing SD control / scheduled | Median delay control / scheduled | p95 delay control / scheduled |
|---|---:|---:|---:|---:|
| 30 cap, light | 29.93 / 29.94 | 3.73 / 3.40 ms | 15.10 / 15.26 ms | 18.60 / 18.79 ms |
| 40 cap, light | 39.94 / 39.93 | 4.85 / 4.58 ms | 14.23 / 14.58 ms | 21.10 / 21.26 ms |
| 50 cap, light | 49.90 / 49.90 | 4.08 / 3.83 ms | 13.75 / 14.00 ms | 18.46 / 18.37 ms |
| 60 cap, light | 59.88 / 59.88 | 3.55 / 3.45 ms | 13.69 / 14.13 ms | 17.00 / 18.06 ms |
| 60 cap, varying load | 54.32 / 54.39 | 5.07 / 4.96 ms | 25.28 / 24.16 ms | 89.90 / 90.10 ms |

The candidate issued 9,364 timed presentation calls; five targets had already expired at CPU encoding and fell back. Approximately 87–89% of loaded frames finished their final GPU work after the target. That estimate uses the adjacent benchmark input timestamp rather than the exact scheduling hook timestamp.

The approximately 6% spacing improvement at 40–50 FPS came with 0.25–0.35 ms more median delay. At 60 FPS the candidate runs disagreed on cadence and average p95 delay increased by about 1 ms. Under changing load, spacing improved only about 2%, throughput was unchanged and the long frame-age tail remained. No visible smoothness or physical response improvement was demonstrated in this round.

Long stalls remain in the results: one candidate 30 FPS sample had a 100 ms display gap and one control had a 104 ms gap. Roughly 70 ms occurred before CPU submission, so the final presentation wait was not their origin. The underlying CPU cause was not profiled. A loaded control also contained a 54 ms gap.

An exploratory subset of the middle 0.2–0.9 seconds of approximately 45 FPS GPU-load plateaus showed control GPU-completion spacing SD of 0.14–0.16 ms, compared with presentation spacing SD of 5.11–5.15 ms. Scheduled samples measured about 4.09 ms presentation SD, with essentially unchanged approximately 70 ms frame age. Load boundaries were inferred from submission time and excluded only for this exploratory analysis, not the headline table. A dedicated sustained plateau experiment is needed before treating this as a reliable improvement.

## Fullscreen freezes and lifecycle handling

Early live ProMotion toggles caused whole-desktop freezes requiring a restart. A macOS 27.0.1 WindowServer watchdog report recorded 40 seconds without a successful display-service check-in; Minecraft was blocked in `MTLCommandBuffer waitUntilCompleted`. That identifies a display/GPU stall, not its sole initiating cause.

One implementation could invalidate a link with frames still in flight. A later native-fullscreen trace showed the render thread stop at its normal GPU fence before link invalidation: retirement had stopped servicing the private run-loop mode that delivered callbacks.

The lifecycle fixes retained encoded and submitted drawables/command buffers until completion, deferred layer reconfiguration, coalesced pending changes and invalidated only after retirement. They serviced the private run loop during close polling and GPU waits, including registered links that were retiring. The private mode also needed Core Animation common-mode observers so transactions could reach the compositor.

A targeted regression made GPU progress depend on work scheduled in that run-loop mode. The old implementation failed and the revised implementation passed. Native SDR/HDR checks covered pixels, resizing, hide/restore, delayed and uncommitted GPU work, and 24 delayed transitions. Windowed Minecraft toggles also passed.

This does not conclusively resolve the original fullscreen system freeze. Native fullscreen/Spaces and exclusive fullscreen exposed different behavior. Later performance comparisons fixed fullscreen/HDR/pacing at process startup; repeated successful sessions did not test live switching, moving between displays or sleep/wake.

Diagnostics used an independent watchdog that made no Metal/AppKit calls and flushed a bounded history of acquisition, GPU waits, commit/present and lifecycle markers. Transition records were persisted before proceeding. Such instrumentation can preserve useful evidence, but does not guarantee recovery from a driver or WindowServer hang. Timeouts must never free unfinished GPU resources as a recovery shortcut.

## Visual tearing observations

A corrected constant-angular-speed pan across a striped wall compared existing VSync, candidate VSync and actual VSync off in separate fixed-mode fullscreen sessions. The user saw no obvious tearing in the first two and visible tearing in the unsynchronized control. The two synchronized modes looked alike; the test did not demonstrate a visual advantage for the candidate or universal absence of tearing.

An earlier sinusoidal camera sweep accelerated around the wall's center. GPU-work changes also coincided with the crossing. Correcting those test conditions removed the reported center-crossing stutter.

An early unsynchronized control failed its settings check: `mcopt.metal.paceSync` kept native synchronization active despite the Minecraft option being off. The corrected control explicitly disabled that override. Always inspect native `displaySyncEnabled`, not just the settings screen.

## Measurement pitfalls and validation

- Preserve selected-frame identity through staging, replacement and presentation. Otherwise frame-age measurements can silently refer to the wrong image.
- Count missing notifications, duplicates, intentional replacements and hidden-window drops separately. Do not silently drop unexplained missing data or turn notification absence into evidence of successful presentation.
- Use actual `presentedTime`; callback arrival and GPU completion are different events. Preserve signed timing deltas where timestamps do not have an established ordering.
- Check focus, actual FPS cap, HDR, fullscreen type, VSync, drawable dimensions/count and clock calibration. Requested preferences alone are insufficient.
- Inject synthetic GPU work before the staging copy/completion signal. Older load helpers appended work after that signal, which could let presentation bypass the intended load; those runs are unsuitable as direct controls for the revised protocol.
- Change workload by elapsed time rather than rendered-frame count. A slower candidate must not receive a different wall-clock workload sequence.
- Separate Metal API validation from performance collection. Correctness checks included 300,000 concurrent mailbox publications and 48 real-Metal SDR/HDR cycles per selection mode, with unfinished-frame fences, pixel readback, ownership, resize/reuse and stale-input handling.
- Keep raw stalls and report tail distributions alongside averages. Do not average away large unexplained differences between control sessions.
- Physical latency and panel refresh require additional measurement. Neither successful API calls nor a reported 120 Hz callback rate proves G-Sync-equivalent behavior.

## Useful next investigations

The strongest unresolved lead is regular GPU completion followed by irregular presentation during sustained lower-FPS workloads. First isolate a sustained approximately 45 FPS GPU-bound plateau, retaining full frame identity and coverage. Then compare ordinary presentation with a target informed by measured GPU readiness/completion cadence and actual presentation feedback.

The latest extra marker showed final presentation GPU work finishing a median 0.06–1.29 ms after render completion, followed by roughly 15 ms until reported presentation in loaded 120-cap samples. This suggests investigating scheduling/queue residence rather than optimizing only that final GPU pass. It does not prove the compositor or panel alone caused all delay.

Keep CPU production stalls separate: some variation already appears between input polling and CPU submission. Avoid increasing a fixed deadline budget merely to smooth a graph with older frames. Preserve GPU overlap, and require consistent throughput, cadence and frame-age gains across repeated runs before recommending a default change.

## Reproduction and retained evidence

The following tools and options belong to the published experimental checkout. They are not assumed to exist in upstream main or release jars. Obtain the checkpoint and cached test dependencies described in the [handoff](../../PROMOTION_HANDOFF.md) before using them. Start each policy in a separate process; these instructions do not validate live fullscreen toggles.

The latest candidate options are `-Dmcopt.metal.presentFresh=true` and, separately, `-Dmcopt.metal.presentScheduleMs=11`. Their defaults are false and zero respectively. Both require the acquisition-worker presentation path, `mcopt.metal.presentQueue=acquire`. The 11 ms value is an experiment, not a recommended player setting.

Correctness checks, from the experimental repository root:

```sh
python3 tools/presentation/check-fresh.py --output /tmp/promotion-check
```

For a low-FPS deadline comparison, substitute absolute paths to the experimental jar, JDK 25 and a new output directory:

```sh
python3 tools/presentation/run-fresh.py /absolute/path/to/mod.jar \
  --java-home /absolute/path/to/jdk25 \
  --output /absolute/path/to/new-results-directory \
  --fullscreen --schedule-ms 11 \
  --phases 30,40,50,60,60g --sample-ms 20000 \
  --load-scale 2 --load-step-ms 1000
python3 tools/presentation/fresh-compare.py /absolute/path/to/new-results-directory
```

The runner uses disposable worlds and cached Prism dependencies. Each session must remain focused. `--schedule-ms 11` isolates timed presentation with fresh-image replacement disabled in both modes. Omit that option to compare fresh-image selection instead. Calibrate the workload on the test GPU; a 60 FPS cap alone does not establish GPU-bound delivery below 60 FPS.

Retained evidence locations, relative to the local investigation workspace, are listed for locating the original records. They are not public download links or files bundled with this reference:

| Evidence | Retained location |
|---|---|
| Early display-link and queue experiments | `work/hdr-pr` branch `fix/promotion-precise-cap`, `tools/presentation/README.md` |
| Current implementation and results | `work/hdr-pr` branch `feat/promotion-lowfps-schedule`, `tools/presentation/README.md` |
| Native fullscreen freeze trace | `work/promotion/crash-2026-10-19-1738/RESUME-NOTES.txt` and adjacent records |
| Earlier timing and visual comparisons | `work/promotion/pacing-ab/` |
| Completed-image overview | `work/promotion/freshness-results.md` |
| Completed-image timing refinements | `work/promotion/fresh14/fullscreen-abba/` |
| 30–60 FPS selection comparison | `work/promotion/lowfps/fullscreen-abba/` |
| Fixed-deadline pilot | `work/promotion/schedule15/pilot12/` |
| Fixed-deadline repeated comparison | `work/promotion/schedule15/fullscreen11-abba/` |

The latest tested diagnostic jar `.15` has SHA-256 `d95ce2e2ee4dcd715de20bd6e436a4bdc46093a2a93df57e94691da3adb6d2fd`.

## External implementation references

- [Apple WWDC21 variable refresh guidance](https://developer.apple.com/videos/play/wwdc2021/10147/) discusses GPU-duration-based scheduling, minimum-duration presentation and display-link timing. Its platform-specific guidance should not be treated as a measurement of this Minecraft integration.
- [SDL Metal latency investigation](https://github.com/libsdl-org/SDL/issues/14456) discusses input sampling, blocking drawable acquisition and display scheduling. It is useful implementation context rather than a validated drop-in fix here.
- [DXMT pacing documentation](https://github.com/3Shain/dxmt/blob/main/docs/CUSTOMIZATION.md) recommends preferred rates that divide the display refresh rate.
- [Unity macOS display-link implementation discussion](https://discussions.unity.com/t/stuttering-in-2023-2-and-6000-0-in-a-minimal-urp-project-on-macos/1525359?page=3) documents opt-in `CAMetalDisplayLink` support, including its 6000.3.11f1 backport. Engine precedent does not guarantee the same result in this renderer.

These sources were checked on 25 October 2026. No new live tests were run to prepare this reference.
