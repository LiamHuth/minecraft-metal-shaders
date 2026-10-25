"""Compare per-session results without treating thousands of frames as independent trials."""
import argparse
import json
import statistics
from pathlib import Path

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('matrix', type=Path)
a = p.parse_args()
sessions = [(s.parent.name, json.loads(s.read_text())) for s in sorted(a.matrix.glob('*/summary.json'))]
if not sessions:
    raise SystemExit('No session summaries found')
rows = {}
protocols = {}
for session, phases in sessions:
    for phase, row in phases.items():
        if not row['validForComparison'] or row['presentationBeforeGpuCompletion']:
            raise SystemExit(f'Invalid measurements in {session}/{phase}; inspect before comparing')
        context = row['windowContext']
        protocol = (row['cap'], row['variableGpuLoad'], row.get('loadScale', 1), row.get('loadStepMs', 237),
                    row['fullscreen'], context['hdr'], context['vsync'], context['drawableCount'],
                    context['drawableWidth'], context['drawableHeight'], context['screen'], context['maximumFPS'])
        if protocols.setdefault(phase, protocol) != protocol:
            raise SystemExit(f'Mismatched workload or display settings in {session}/{phase}')
        rows.setdefault(phase, {}).setdefault('candidate' if row['fresh'] else 'baseline', []).append(row)

def average(group, key, subkey=None):
    return statistics.mean(r[key][subkey] if subkey else r[key] for r in group)

report = {}
print('Per-session means; latency is input-poll → presentedTime, not input-to-photon.')
print('| Phase | Mode | Runs | Shown FPS | Interval SD ms | Median delay ms | p95 delay ms | Replacements |')
print('|---|---|---:|---:|---:|---:|---:|---:|')
for phase, groups in rows.items():
    report[phase] = {}
    for mode, group in groups.items():
        values = {
            'runs': len(group), 'fps': average(group, 'displayedFps'),
            'intervalStddevMs': average(group, 'intervalMs', 'stddev'),
            'intervalP95Ms': average(group, 'intervalMs', 'p95'),
            'intervalP99Ms': average(group, 'intervalMs', 'p99'),
            'meanAbsoluteIntervalErrorMs': average(group, 'meanAbsoluteIntervalErrorMs'),
            'longIntervalPercent': statistics.mean(100 * r['longIntervalsOver1_5Periods'] / r['intervalMs']['n'] for r in group),
            'medianDelayMs': average(group, 'pollToPresentationMs', 'p50'),
            'p95DelayMs': average(group, 'pollToPresentationMs', 'p95'),
            'replacements': sum(r['queueDelta']['replacements'] for r in group),
            'checks': sum(r['queueDelta']['checks'] for r in group),
        }
        report[phase][mode] = values
        print(f"| {phase} | {mode} | {values['runs']} | {values['fps']:.2f} | {values['intervalStddevMs']:.2f} | "
              f"{values['medianDelayMs']:.2f} | {values['p95DelayMs']:.2f} | {values['replacements']} |")
(a.matrix / 'comparison.json').write_text(json.dumps(report, indent=2) + '\n')
