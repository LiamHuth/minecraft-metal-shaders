"""Summarize Metal presentation timestamps; these do not measure physical scanout."""
import argparse
import collections
import json
import math
import statistics
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("report", type=Path)
args = parser.parse_args()
data = json.loads(args.report.read_text())

def stats(values):
    values = sorted(values)
    if not values:
        return None
    return dict(mean=statistics.mean(values), median=statistics.median(values),
                p95=values[math.ceil(len(values)*.95)-1], sd=statistics.pstdev(values))

out = []
for phase in data["phases"]:
    start, end = phase["begin"], phase["end"]
    rows = [r for r in data["samples"] if r[0] == phase["phase"] and start <= r[1] < end]
    shown_raw = [r[4] for r in rows if start <= r[4] < end]
    shown = sorted(set(shown_raw))
    intervals = [(b-a)*1000 for a,b in zip(shown,shown[1:])]
    latency = [(r[4]-r[1])*1000 for r in rows if r[1] <= r[4] < end]
    gpu = [(r[3]-r[2])*1000 for r in rows if 0 < r[2] <= r[3]]
    missing = sum(r[4] == 0 for r in rows)
    duplicate = len(shown_raw) - len(shown)
    missing_callbacks = sum(r[5] == 0 for r in rows)
    invalid_timing = sum(not (0 < r[1] <= r[2] <= r[3]) or
                         (r[4] > 0 and r[4] < r[1]) for r in rows)
    result = {**phase, "frames": len(rows), "missing": missing,
        "missingCallbacks": missing_callbacks, "duplicatePresentationTimes": duplicate,
        "invalidTiming": invalid_timing,
        "unfocused": sum(not r[6] for r in rows), "intervalMs": stats(intervals),
        "renderStartToPresentedMs": stats(latency), "gpuMs": stats(gpu),
        "intervalBinsMs": dict(sorted(collections.Counter(round(x*2)/2 for x in intervals).items()))}
    result["valid"] = bool(len(intervals) > 20 and not missing and not missing_callbacks
                           and not duplicate and not invalid_timing and not result["unfocused"])
    result["fps"] = 1000/statistics.mean(intervals) if intervals else None
    out.append(result)
    print(json.dumps(result))
args.report.with_suffix(".summary.json").write_text(json.dumps({
    "timingMeaning": "After pre-frame wait/drawable acquisition to Metal presentedTime; no input sampling or physical scanout measurement.",
    "context": {k:v for k,v in data.items() if k not in {"samples", "phases"}}, "phases": out}, indent=2)+"\n")
if not all(p["valid"] for p in out):
    raise SystemExit("Incomplete presentation coverage or focus: do not claim a fully valid comparison.")
