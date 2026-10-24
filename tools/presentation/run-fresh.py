"""Run fixed-setting A/B/B/A sessions; each uses a disposable world and exits itself."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('jar', type=Path)
p.add_argument('--java-home', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--fullscreen', action='store_true')
p.add_argument('--sdr', action='store_true')
a = p.parse_args()
a.output = a.output.resolve()
a.output.mkdir(parents=True, exist_ok=False)
here = Path(__file__).resolve().parent
for i, enabled in enumerate([False, True, True, False]):
    output = a.output / f'{i}-{"fresh" if enabled else "baseline"}'
    command = [sys.executable, here / 'fresh-bench.py', a.jar.resolve(), '--java-home', a.java_home, '--output', output]
    if enabled: command.append('--fresh')
    if a.fullscreen: command.append('--fullscreen')
    if a.sdr: command.append('--sdr')
    print(f'Starting {output.name}', flush=True)
    # fresh-bench owns and bounds its game child. Stop on any failed game run.
    subprocess.run(list(map(str, command)), check=True)
    analyzed = subprocess.run([sys.executable, str(here / 'fresh-analyze.py'), str(output / 'measurements.json')])
    summary = json.loads((output / 'summary.json').read_text())
    if analyzed.returncode not in (0, 2) or not all(row['validContext'] for row in summary.values()):
        raise RuntimeError('Invalid test context; stopped before further sessions')
    if analyzed.returncode:
        print('Incomplete timestamp coverage retained and flagged; continuing the counterbalanced matrix.', flush=True)
print('All four sessions have closed. Results:', a.output, flush=True)
