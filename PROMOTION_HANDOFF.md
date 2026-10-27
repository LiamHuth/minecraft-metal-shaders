# ProMotion experiments: contributor handoff

Published for [issue #11](https://github.com/GaelQuinta/minecraft-metal-shaders/issues/11), 27 October 2026.

These are experimental source checkpoints, not a recommended replacement for the release. We did not establish a consistent lower-FPS smoothness improvement without tradeoffs. The code, test harnesses, and unsuccessful approaches are shared so the next investigation can build on them.

## Start here

| Branch | Tested code checkpoint | Contents |
|---|---|---|
| [`feat/promotion-lowfps-schedule`](https://github.com/LiamHuth/minecraft-metal-shaders/tree/feat/promotion-lowfps-schedule) | `0233045` | Latest starting point, based on upstream `cc35628`: fresher completed-frame selection and a separate input-relative presentation-deadline experiment. Includes the 30–60 FPS comparison tools. |
| [`fix/promotion-precise-cap`](https://github.com/LiamHuth/minecraft-metal-shaders/tree/fix/promotion-precise-cap) | `69a49c6` | Earlier work based on `v1.2.5-alpha` (`a5b5a98`), including display-link clocks, render-budget prediction, presentation-duration policies, queue limits, lifecycle diagnostics, and visual tearing tests. |

The latest branch restarted from newer upstream code and does not include the older display-link scheduler. The older branch's history includes the original direct `CAMetalDisplayLink` implementation (`c75bd35`) and its lifecycle corrections through `e318ee7`; its tip uses `CADisplayLink` as a timing source with ordinary layer drawables. Check those historical commits when investigating the original API integration. The older branch also includes the shadowed-sun haze fix; the two branches are separate experimental lines, not a sequence to merge blindly.

The published tips add documentation to the tested checkpoints without changing runtime code. Keep the original commits available when reproducing the recorded results.

- [Detailed measurements, rejected approaches, lifecycle findings, and next leads](tools/presentation/REFERENCE.md)
- [Branch-specific implementation notes and test commands](tools/presentation/README.md)

The reference contains result summaries. Original raw captures and crash logs remain in the local investigation workspace; paths mentioned there are not bundled downloads.

## Build

Use an Apple Silicon Mac, JDK 25, and Apple's command-line development tools with a macOS SDK. The native build targets macOS 15 or later. Network access is needed for uncached Gradle dependencies.

```sh
git clone --branch feat/promotion-lowfps-schedule https://github.com/LiamHuth/minecraft-metal-shaders.git
cd minecraft-metal-shaders
export JAVA_HOME="$(/usr/libexec/java_home -v 25)"
./gradlew :metal:clean :metal:build
```

The mod JAR is written to `metal/build/libs/`. Use it in a separate Minecraft 26.3/Fabric instance, replacing the existing Metal Shaders JAR. Both branches retain the release version in their build metadata, so label local copies by branch and commit. Rebuild cleanly after switching branches.

## Compare the latest experiments

Keep shaders and VSync enabled, and keep resolution, HDR, scene, and FPS cap identical. The latest options are startup-only; compare separate game processes. Explicit settings for the unchanged control are:

```text
-Dmcopt.metal.presentQueue=acquire
-Dmcopt.metal.presentFresh=false
-Dmcopt.metal.presentScheduleMs=0
```

Test one change at a time:

- Completed-frame selection: change `presentFresh` to `true`, leaving `presentScheduleMs=0`.
- Presentation deadlines: keep `presentFresh=false` and change `presentScheduleMs` to `11`.

Both experiments default to off. The 11 ms budget is a tested example, not a recommended setting. These options do not enable VRR, replace VSync, or generate frames.

On the older branch, the corresponding entry point is `-Dmcopt.metal.displayLink=true`; see that branch's README for its separate policy options. Do not carry those arguments into the latest branch expecting the same scheduler.

## Reproduce measurements

The native correctness check on the latest branch does not require a Minecraft window:

```sh
python3 tools/presentation/check-fresh.py --output /tmp/promotion-check
```

The live runners additionally expect Python 3 and locally cached Prism Launcher dependencies at `~/Library/Application Support/PrismLauncher`: Minecraft 26.3, Fabric Loader 0.19.5, LWJGL 3.4.3, and the game's assets. They do not download these dependencies; install/launch a matching Prism instance first, or adapt the cache paths and versions in the scripts. They create disposable offline profiles/worlds and do not use an existing save.

The latest runner compares control/candidate/candidate/control. Substitute absolute paths and a new results directory:

```sh
python3 tools/presentation/run-fresh.py /absolute/path/to/mod.jar \
  --java-home /absolute/path/to/jdk25 \
  --output /absolute/path/to/new-results-directory \
  --schedule-ms 11 --phases 30,40,50,60,60g \
  --sample-ms 20000 --load-scale 2 --load-step-ms 1000
python3 tools/presentation/fresh-compare.py /absolute/path/to/new-results-directory
```

This command starts windowed. Add `--fullscreen` only when deliberately testing native fullscreen. Omit `--schedule-ms 11` to compare completed-frame selection instead. Each window needs focus; changing focus invalidates the timing comparison. Calibrate the synthetic GPU load for the test machine. A low FPS cap alone is not a GPU-bound workload. Run Metal API validation separately from performance collection.

## Findings and remaining lead

Testing used an M4 Pro MacBook Pro's built-in 120 Hz display on macOS 27.0.1. External-display behavior was not validated. VSync-on visual checks showed no obvious tearing, including the unchanged renderer; the VSync-off control visibly tore. That did not demonstrate an advantage for the candidate.

Completed-frame selection helped frame freshness in some runs rendering above the display rate. At 30–60 FPS there were no replacements and no established benefit. Fixed 11 ms presentation deadlines slightly tightened some 40–50 FPS intervals while adding delay; varying-load improvements were small and inconsistent. Detailed tables and measurement limitations are in the reference.

The most promising unresolved lead was regular GPU completion followed by irregular presentation during sustained roughly 45 FPS GPU load. Isolate that workload, then investigate scheduling informed by actual GPU readiness and presentation feedback. Preserve frame identity and count missing callbacks separately from intentional replacements. Compare throughput, frame spacing, and frame age together. Our input-poll-to-`presentedTime` metric is software delay, not physical input-to-photon latency, and does not prove panel VRR.

## Known lifecycle hazard

Early live fullscreen ProMotion toggles caused whole-desktop freezes requiring a restart. Later lifecycle fixes passed targeted regressions, but the original system-level failure was not conclusively resolved. Start windowed and keep HDR, fullscreen, and pacing fixed from process startup. Older README sections describe live-toggle functionality; they are not a current recommendation to use it. Successful fixed-mode fullscreen sessions do not establish safe live switching, sleep/wake, or display migration. A test timeout cannot recover a hung WindowServer, and unfinished GPU resources must not be freed as a timeout recovery shortcut.
