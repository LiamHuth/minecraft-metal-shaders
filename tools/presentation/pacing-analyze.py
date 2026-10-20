"""Summarize only steady measurement windows and report invalid coverage explicitly."""
import argparse
import collections
import json
import math
import statistics
import sys
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("report", type=Path)
args = parser.parse_args()
data = json.loads(args.report.read_text())
gpu = data["gpu"]

def percentile(values, quantile):
    if not values:
        return None
    values = sorted(values)
    return values[max(0, math.ceil(len(values) * quantile) - 1)]

def summary(values):
    return {
        "n": len(values),
        "mean": statistics.mean(values) if values else None,
        "p50": percentile(values, .5), "p95": percentile(values, .95),
        "p99": percentile(values, .99), "max": max(values) if values else None,
        "stddev": statistics.pstdev(values) if values else None,
    }

def fmt(value):
    return "unavailable" if value is None else f"{value:.2f}"

result = {}
for name, phase in data["phases"].items():
    begin, end = phase["nanoRange"]
    expected = "ACTIVE" if phase["enabled"] else "OFF"
    indices = [i for i, yes in enumerate(gpu["presenting"])
               if yes and begin <= gpu["pollNs"][i] < end]
    shown = [gpu["presentedTimeNs"][i] for i in indices if begin <= gpu["presentedTimeNs"][i] < end]
    duplicate_times = len(shown) - len(set(shown))
    ordered = sorted(set(shown))
    intervals = [(b - a) / 1e6 for a, b in zip(ordered, ordered[1:])]
    latency = [(gpu["presentedTimeNs"][i] - gpu["pollNs"][i]) / 1e6 for i in indices
               if begin <= gpu["presentedTimeNs"][i] < end and gpu["pollNs"][i] <= gpu["presentedTimeNs"][i]]
    durations = [(gpu["gpuEndNs"][i] - gpu["gpuStartNs"][i]) / 1e6 for i in indices
                 if 0 < gpu["gpuStartNs"][i] <= gpu["gpuEndNs"][i]]
    target = 1000 / phase["cap"]
    row = result[name] = {
        "cap": phase["cap"], "enabled": phase["enabled"],
        "validContext": phase["fullscreenFrames"] == 0 and phase["unfocusedFrames"] == 0
            and phase["states"] == {expected: phase["frames"]} and phase["hdr"]
            and phase.get("actualCaps") == {str(phase["cap"]): phase["frames"]},
        "states": phase["states"], "unfocusedFrames": phase["unfocusedFrames"],
        "presentingSubmits": len(indices),
        "missingPresentationTimestamps": sum(gpu["presentedTimeNs"][i] == 0 for i in indices),
        "duplicatePresentationTimestamps": duplicate_times,
        "intervalMs": summary(intervals), "pollToPresentationMs": summary(latency),
        "gpuMs": summary(durations),
        "intervalHistogramMs": dict(sorted(collections.Counter(round(x * 2) / 2 for x in intervals).items())),
        "meanAbsoluteIntervalErrorMs": statistics.mean(abs(x - target) for x in intervals) if intervals else None,
        "longIntervalsOver1_5Periods": sum(x > 1.5 * target for x in intervals),
    }
    row["displayedFps"] = 1000 / statistics.mean(intervals) if intervals else None
    row["validForComparison"] = (row["validContext"] and len(intervals) >= 10
        and row["missingPresentationTimestamps"] == 0 and duplicate_times == 0
        and len(latency) == len(shown) and gpu["dropped"] == 0)
    print(f"{name:14} valid={row['validContext']} shown={len(shown)} "
          f"FPS={fmt(row['displayedFps'])} interval mean/p95={fmt(row['intervalMs']['mean'])}/{fmt(row['intervalMs']['p95'])}ms "
          f"jitter SD={fmt(row['intervalMs']['stddev'])}ms "
          f"poll->shown median/p95={fmt(row['pollToPresentationMs']['p50'])}/{fmt(row['pollToPresentationMs']['p95'])}ms "
          f"GPU median={fmt(row['gpuMs']['p50'])}ms")
    print("  interval bins:", row["intervalHistogramMs"])
path = args.report.with_name("summary.json")
path.write_text(json.dumps(result, indent=2) + "\n")
print(path)
if not result or not all(row["validForComparison"] for row in result.values()):
    print("INVALID COMPARISON: check focus, actual cap, pacing state, HDR, and timestamp coverage.", file=sys.stderr)
    raise SystemExit(2)
