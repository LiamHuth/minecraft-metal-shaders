"""Headless concurrency and real Metal staging/selection checks. Opens no window."""
import argparse
from pathlib import Path
import re
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
root = Path(__file__).resolve().parents[2]
a.output = a.output.resolve()
a.output.mkdir(parents=True, exist_ok=False)
here = Path(__file__).resolve().parent
def run(args, **kw):
    subprocess.run(list(map(str, args)), check=True, timeout=120, **kw)

run(['clang', '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror', '-pthread', here / 'freshcheck.c', '-o', a.output / 'freshcheck'])
run([a.output / 'freshcheck'])
# Use exactly the other native translation units from the production build.
build = (root / 'metal/build.gradle').read_text()
names = re.findall(r"'([^']+\.(?:m|c))'", build.split('def sources =', 1)[1].split('.collect', 1)[0])
sources = [root / 'metal/src/main/native' / n for n in names if n != 'mcmetal.m']
run(['clang', '-fno-objc-arc', '-O2', '-Wall', '-arch', 'arm64', '-mmacosx-version-min=15.0',
     here / 'freshgpu.m', *sources,
     *[x for framework in ['AppKit', 'CoreGraphics', 'CoreVideo', 'Foundation', 'Metal', 'QuartzCore'] for x in ['-framework', framework]],
     '-o', a.output / 'freshgpu'])
for mode in ['0', '1']:
    run([a.output / 'freshgpu', mode])
