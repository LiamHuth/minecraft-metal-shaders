# Completed-frame presentation experiment

This branch starts from upstream `main` at `cc35628` (2026-10-23). It keeps the
existing acquisition worker, VSync, and drawable pool. It does not use the earlier
experimental display-link scheduler or change refresh rates.

Enable the candidate at game startup with:

```text
-Dmcopt.metal.presentFresh=true
```

The default is off; omit the argument or set it to `false` for the control. It
requires `presentQueue=acquire`, already the shader renderer's default. Restart
between comparisons; this experiment has no live display-mode toggle.

## What changes

The worker normally chooses a staging image before calling `nextDrawable`. If
that call blocks, a newer image can become available while it waits. The candidate
makes one nonblocking attempt to claim that newer image after acquisition, but
only when the newer image's GPU work has completed. Otherwise it presents the
original selection immediately.

Fills remain ordered on the existing render queue and use its device-local Metal
event. Completion handlers publish a monotonic CPU watermark; out-of-order
callbacks cannot move it backwards. Delayed callbacks can miss an opportunity,
but cannot make an unfinished image eligible. A successful atomic mailbox claim
transfers slot ownership before metadata is read. The newer completed fill also
fences the discarded older fill, allowing the old slot to be safely reused.

Presented callbacks follow the selected frame's identity. The diagnostic recorder
distinguishes presented frames, replacement before/after drawable acquisition,
and hidden-window drops. Intentional replacements must not be counted as missing
timing measurements.

An earlier prototype (`6514aee`, diagnostic jar `.11`) used a CPU-readable shared
Metal event instead. Its fullscreen A/B/B/A runs showed roughly 2.6–2.9 ms more
median input-poll-to-presentation delay in light scenes and lower loaded FPS.
That version was rejected. The current completion-handler implementation avoids
changing the GPU event type.

## Input-relative presentation scheduling experiment

`-Dmcopt.metal.presentScheduleMs=11` enables a separate, startup-only experiment on
this branch. Zero (the default) keeps ordinary presentation. A native timestamp
immediately after input polling defines an earliest presentation target for that
frame. The target follows its staging slot; the worker uses
`presentDrawable:atTime:` only while the target is in the future and VSync is on.
Missing or stale input timestamps bypass scheduling. This adds no CPU sleep, GPU
fence or display-link callback, and does not change the existing drawable count.
It requires `mcopt.metal.presentQueue=acquire`.

The parameter is an experimental fixed time budget, not an adaptive algorithm or
a recommended user setting. A frame can finish after its target and be shown
late. Even a frame that finishes early may wait longer than with ordinary
presentation. This must be measured against both cadence and latency, especially
when the GPU cannot keep up with the FPS cap.

Pass `--schedule-ms 11` to `run-fresh.py` to compare this policy against disabled
scheduling in A/B/B/A order. The runner leaves fresh-frame replacement disabled in
both modes, isolating the scheduling change. Native counters verify the configured
budget and count timed presents versus targets already expired at CPU encoding.
An unexpired target does **not** mean the GPU will finish by that time. Reports and
manifests record the policy; comparisons reject mixed candidate budgets.

## Correctness checks

```sh
python3 tools/presentation/check-fresh.py --output /tmp/fresh-check
```

Requires the native build's Apple toolchain and permission to access Metal.
The headless checks exercise the production code without creating a window:

- 300,000 concurrent mailbox publications with slot ownership assertions.
- Out-of-order completion notifications and monotonic readiness.
- Real Metal fills deliberately blocked on a GPU fence: an unfinished image must
  remain pending, and selection must not wait for it.
- SDR/HDR pixel readback, selected-frame identity, resize/reuse, and slot release.

For CPU race detection, compile `freshcheck.c` with `-fsanitize=thread -pthread`.
For GPU validation, run the headless check with `MTL_DEBUG_LAYER=1`. Do not enable
validation while collecting performance measurements.

## Live comparison

```sh
python3 tools/presentation/run-fresh.py /absolute/path/to/mod.jar \
  --java-home /absolute/path/to/jdk25 \
  --output /absolute/path/to/new-results-directory --fullscreen
python3 tools/presentation/fresh-compare.py /absolute/path/to/new-results-directory
```

Omit `--fullscreen` for windowed comparisons; add `--sdr` for SDR. The runner uses
locally cached Prism Minecraft 26.3, LWJGL 3.4.3, and Fabric Loader 0.19.5. It creates
disposable profiles/worlds under `/private/tmp` and leaves existing Prism instances
alone. Each session must remain focused. Four separate game processes run in
A/B/B/A order with fixed startup fullscreen, HDR, VSync, and presentation settings.
Each process closes automatically and has a bounded timeout.

Each session measures 50/60/120 FPS caps with light load and a 120 FPS cap with
varying GPU load. The latter changes compute work every 237 ms, including periodic
heavier steps. It is injected before the staging copy/event signal so presentation
cannot bypass that work. Older probes appended load after that signal, making
their loaded results unsuitable as a direct control for this protocol.

For longer measurements use `--sample-ms 20000`. For the higher-cap comparison use
`--phases 120,120g,240,240g`; `g` enables the changing GPU load. Set
`--output-height 0` to test native resolution instead of the default 900p fullscreen
output. Always compare A and B with the same phase plan and resolution.

For the lower-rate comparison use `--phases 30,40,50,60,60g --sample-ms 20000
--load-scale 2 --load-step-ms 1000`. The GPU workload multiplier affects only the
`g` phase. This keeps the four capped, lightly loaded cases separate from a 60 FPS
cap with changing GPU pressure. The default multiplier is 1 and default step is
237 ms, preserving the earlier protocol. Calibrate the multiplier on the test GPU;
the cap alone does not establish which frame rates the changing-load phase reaches.
The manifest records the workload settings and hashes the Java/native harness.

Native context records actual fullscreen, focus, HDR, VSync, drawable dimensions,
drawable count, and screen refresh capabilities. The report preserves raw frame
timestamps and explicit drop outcomes. Analysis rejects unexplained missing or
contradictory timestamps and invalid focus/settings. Comparisons average session
statistics rather than treating every individual frame as an independent trial.
The analyzer also exports complete one-second presentation counts, frame-spacing
tails, long-gap counts, and separate input-poll/submission/GPU-completion intervals.
The comparison rejects mixed workload or display settings within a phase.

## Interpretation limits

`pollToPresentationMs` measures time from the game's input poll to Metal's
`presentedTime`. It is a software estimate, not physical input-to-photon latency.
The replacement counter proves that the path ran; selected-frame age saved does
not prove the same reduction in end-to-end latency. Presentation timestamps alone
cannot prove absence of tearing or establish that the panel changed refresh rate.
VSync remains enabled in these comparisons.

Keep the feature opt-in unless repeated tests show better delay with equal or
better frame delivery and consistency. Correct frame selection is necessary, but
is not by itself evidence of a better playing experience.

## Results on the M4 Pro, 2026-10-24

The completion-readiness candidate (`842be91`, diagnostic jar `.12`) was compared
with its disabled control in two fullscreen A/B/B/A sets, on the built-in 120 Hz
display with HDR and VSync. All sessions passed context and timestamp checks.
These are averages of the per-session statistics from the longer set:

| Workload | Control / candidate displayed FPS | Control / candidate median delay |
|---|---:|---:|
| 120 FPS cap, light | 119.53 / 119.50 | 14.92 / 14.64 ms |
| 120 FPS cap, varying GPU load | 106.01 / 106.41 | 31.63 / 30.59 ms |
| 240 FPS cap, light | 120.00 / 120.00 | 39.36 / 30.96 ms |
| 240 FPS cap, varying GPU load | 105.33 / 105.68 | 37.63 / 37.41 ms |

The meaningful repeatable gain was at the higher cap with light GPU load: 2,541
refresh replacements across the two candidate samples, and about 8.4 ms less
median delay with unchanged 8.33 ms frame spacing. There were no refresh
replacements in those 120 FPS samples, so their small timing differences should
not be interpreted as an improvement caused by replacement. Raising the cap was
still worse for latency than staying at 120 in the light scene.

A follow-up prototype (`.13`) handed frames to the worker only after GPU
completion. It passed correctness checks but reduced loaded throughput to about
94–95 FPS and substantially increased frame-time spikes. It was rejected; that
publication change is not in this branch's current implementation.

The candidate remains off by default. It is a limited queue-freshness improvement,
not a solution to adaptive refresh or all sub-120 FPS pacing problems.

Additional checks used native 3456×2168 fullscreen output, windowed HDR, and a
fixed-startup SDR session. Native-resolution loaded averages were 91.71 FPS for
the control and 90.97 FPS for the candidate, with median delays of 33.95 and
33.03 ms; neither candidate run replaced a frame. This does not establish a useful
improvement under sustained GPU pressure.

Windowed results also do not establish a latency benefit: the control itself
changed substantially between sessions (at 50 FPS, 16.42 to 29.46 ms median delay).
The candidate's two windowed runs were close to the latter control. The reason
for that session-to-session shift is not established by these measurements, so
averaging it away would overstate confidence in either a benefit or a regression.

Diagnostic jar `.14` keeps the `.12` selection behavior and adds the presentation
command buffer's GPU-end timestamp to the opt-in recorder. It uses the existing
completion handler, captures the selected frame's identity, and does not add a
GPU fence. `renderEndToPresentGpuEndMs` and `presentGpuEndToShownMs` split the
remaining software delay; both retain signed deltas and report missing coverage.
They still do not measure physical display scanout or input-to-photon latency.

The final `.14` fullscreen A/B/B/A check showed 106.81 / 106.85 displayed FPS and
30.84 / 30.57 ms median delay under varying GPU load at a 120 FPS cap: effectively
unchanged. The final presentation GPU work finished a median 0.06–1.29 ms after
the render command buffer, followed by roughly 15 ms until reported presentation
in loaded samples. That directs the next investigation toward presentation
scheduling, rather than the cost of the final GPU pass.

At the 240 FPS cap, this final set averaged 34.32 / 29.73 ms median delay and
41.33 / 33.47 ms at the 95th percentile. However, the two control medians differed
substantially (39.28 and 29.36 ms), so a fixed 8 ms median improvement is not
established across all runs. The reduction in tail delay was more consistent.
Displayed rates were 120.00 / 119.95 FPS. All final presentation GPU timestamps
were present. Across these experiments, 30 fixed-mode game sessions completed
without a crash or freeze; live fullscreen/HDR/pacing transitions were not tested.

### 30–60 FPS follow-up, 2026-10-24

Four additional fullscreen A/B/B/A sessions used the unchanged `.14` jar on the
built-in 120 Hz display, HDR, VSync and 1434×900 shader output. Each session measured
20 seconds at each of 30/40/50/60 FPS, then a 60 FPS cap with doubled GPU work
changing every second. The changing workload produced approximately 34–35, 45–46
and 58–62 presentations per one-second window; counts just above 60 reflect frames
crossing workload/window boundaries, not a change to the cap. A separate short
calibration preceded the matrix. All focus/settings/coverage checks passed, all
presentation GPU-end timestamps were present, and every game process closed.

These are means of two session statistics per mode, not pooled independent frames:

| Workload | Control / candidate FPS | Frame-spacing SD | Median poll-to-present | p95 poll-to-present |
|---|---:|---:|---:|---:|
| 30 cap, light | 29.97 / 29.97 | 3.00 / 2.93 ms | 14.96 / 15.21 ms | 18.52 / 18.66 ms |
| 40 cap, light | 39.94 / 39.93 | 5.07 / 4.76 ms | 14.65 / 14.36 ms | 21.50 / 21.03 ms |
| 50 cap, light | 49.90 / 49.92 | 4.00 / 4.09 ms | 13.65 / 13.76 ms | 18.22 / 18.54 ms |
| 60 cap, light | 59.87 / 59.89 | 3.52 / 3.68 ms | 13.66 / 13.72 ms | 17.14 / 17.64 ms |
| 60 cap, varying GPU load | 54.38 / 54.38 | 5.02 / 5.04 ms | 24.16 / 23.54 ms | 90.53 / 90.59 ms |

No candidate sample replaced a frame. The small differences do not establish a
benefit; this mechanism did not address low-FPS smoothness. The 95th-percentile
display intervals were the same in both modes at every phase: 37.50, 33.33, 25.00,
20.83 and 29.17 ms respectively. No measured display gap exceeded 50 ms. The large
loaded latency tail is frame age, not a 90 ms gap between displayed frames.

The steady caps already poll input regularly. At 40 FPS, for example, baseline
interval SD grows from 0.06 ms at input polling to 2.50 ms at CPU submission,
2.79 ms at render GPU completion, and 5.07 ms at presentation. That directs future
investigation toward both frame production and display scheduling; the limiter
alone, or only the final GPU pass, cannot explain all the variation. These stages
are correlated and their standard deviations must not be added together.

This is a fixed-camera, synthetic GPU-load timing test, not a visual assessment,
physical latency measurement, or coverage of chunk-loading/GC stalls. No production
renderer behavior was changed for this follow-up. The candidate remains off by
default. Raw reports and manifests are saved in the workspace under
`work/promotion/lowfps/fullscreen-abba`.

### Input-relative deadline experiment, 2026-10-24

Diagnostic `.15` adds the optional scheduling policy described above. A 12 ms,
10-second-per-phase pilot showed small cadence changes and some extra latency.
The controlled follow-up used an 11 ms budget and four 20-second-per-phase
fullscreen sessions in A/B/B/A order, with the same 30/40/50/60/60g protocol as the
previous experiment. All four used the identical jar and harness hashes, built-in
120 Hz screen, HDR, VSync, three drawables and 1434×900 output. Every session passed
focus, actual-cap, display-context and timestamp checks and closed normally.

Means of two session statistics per mode (control / scheduled):

| Workload | Displayed FPS | Frame-spacing SD | Median poll-to-present | p95 poll-to-present |
|---|---:|---:|---:|---:|
| 30 cap, light | 29.93 / 29.94 | 3.73 / 3.40 ms | 15.10 / 15.26 ms | 18.60 / 18.79 ms |
| 40 cap, light | 39.94 / 39.93 | 4.85 / 4.58 ms | 14.23 / 14.58 ms | 21.10 / 21.26 ms |
| 50 cap, light | 49.90 / 49.90 | 4.08 / 3.83 ms | 13.75 / 14.00 ms | 18.46 / 18.37 ms |
| 60 cap, light | 59.88 / 59.88 | 3.55 / 3.45 ms | 13.69 / 14.13 ms | 17.00 / 18.06 ms |
| 60 cap, varying GPU load | 54.32 / 54.39 | 5.07 / 4.96 ms | 25.28 / 24.16 ms | 89.90 / 90.10 ms |

The candidate made 9,364 timed presentation calls across its measurement windows;
five targets had already expired at CPU encoding and used ordinary presentation.
The policy definitely ran, but these counters do not imply on-time GPU completion.
About 87–89% of frames in the loaded candidate samples completed their final GPU
work after the input-relative target. This estimate uses the benchmark input
stamp adjacent to the native scheduling hook, not that hook's exact timestamp.

The roughly 6% reduction in spacing SD at 40 and 50 FPS came with 0.25–0.35 ms
higher median software delay. At 60 FPS the candidate runs disagreed on cadence,
and average p95 delay increased by about 1 ms. Under varying load the aggregate
spacing improvement was only about 2%, throughput was unchanged, and the roughly
90 ms tail of input-to-presentation age remained. No consistent improvement in
physical response or visible smoothness has been demonstrated.

Long stalls remain included in the table. One scheduled 30 FPS sample had a
100 ms presentation gap and one control sample had a 104 ms gap. Their timestamp
traces show roughly 70 ms spent before CPU submission, so these two stalls did
not originate in the final presentation wait. Their underlying CPU cause was not
profiled. A control loaded sample also contained a 54 ms gap. Do not discard these
frames or confuse frame age with display gaps.

A post-hoc look at the middle 0.2–0.9 seconds of the ~45 FPS GPU-load plateaus
found GPU-completion spacing SD of 0.14–0.16 ms in the controls, versus reported
presentation spacing SD of 5.11–5.15 ms. Scheduled samples measured about 4.09 ms
presentation SD there, with essentially unchanged ~70 ms frame age. This narrower
result is promising enough for a dedicated repeat, but is exploratory: the load
steps were inferred from submission time, and their boundaries were excluded only
for this diagnostic, not for the headline comparison. It does not establish a
panel scanout or input-to-photon improvement.

The experiment remains disabled by default and is not recommended as a general
ProMotion fix. The next focused test should isolate those GPU-bound ~45 FPS
plateaus, then evaluate a target based on actual GPU completion cadence rather
than assuming every frame will finish 11 ms after input. Do not increase the fixed
budget simply to make the interval graph smoother at the cost of older input.

Validation: the full Java/native build passed, as did the concurrent mailbox test
and 48 real-Metal SDR/HDR cycles in each selection mode, including deadline
ownership and stale-input fallback. Live mode toggles and physical tearing were
not tested. Raw pilot and comparison files are under
`work/promotion/schedule15/pilot12` and
`work/promotion/schedule15/fullscreen11-abba` in the workspace. The tested jar SHA-256
is `d95ce2e2ee4dcd715de20bd6e436a4bdc46093a2a93df57e94691da3adb6d2fd`.
