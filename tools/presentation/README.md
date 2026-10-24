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

Native context records actual fullscreen, focus, HDR, VSync, drawable dimensions,
drawable count, and screen refresh capabilities. The report preserves raw frame
timestamps and explicit drop outcomes. Analysis rejects unexplained missing or
contradictory timestamps and invalid focus/settings. Comparisons average session
statistics rather than treating every individual frame as an independent trial.

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
