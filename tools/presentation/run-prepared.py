"""Run an already prepared comparison after arranging uninterrupted display focus."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("directory", type=Path)
validation = parser.add_mutually_exclusive_group(required=True)
validation.add_argument("--native-check", type=Path)
validation.add_argument("--reuse-validation", type=Path, help="Earlier comparison directory for the identical jar")
parser.add_argument("--native-policy", default="4")
opts = parser.parse_args()
root = opts.directory.resolve()
comparison = json.loads((root / "comparison.json").read_text())
env = {k: v for k, v in os.environ.items() if not k.startswith("MTL_DEBUG")}


def run(args, cwd, log_path, timeout, environment, pid_path=None):
    with log_path.open("x") as log:
        process = subprocess.Popen(args, cwd=cwd, stdout=log, stderr=subprocess.STDOUT, env=environment)
        if pid_path:
            pid_path.write_text(str(process.pid))
        try:
            return process.wait(timeout=timeout)
        except BaseException:
            # Only this supervisor's child; no global Java/application termination.
            process.kill()
            process.wait(timeout=5)
            raise


if opts.reuse_validation:
    previous = opts.reuse_validation.resolve()
    validated = json.loads((previous / "comparison.json").read_text())
    if validated["jarSha256"] != comparison["jarSha256"]:
        raise RuntimeError("Cannot reuse validation from a different jar")
    validation_text = (previous / "validation.log").read_text()
    (root / "validation-source").write_text(str(previous))
else:
    print("Starting windowed SDR/HDR native validation", flush=True)
    code = run([str(opts.native_check.resolve()), "1"], root, root / "validation.log", 100,
               dict(env, MTL_DEBUG_LAYER="1", MCOPT_PRESENT_POLICY=opts.native_policy))
    if code:
        raise RuntimeError("Native validation failed; no Minecraft sessions were launched")
    validation_text = (root / "validation.log").read_text()
if "PASS: display-link teardown/recreate and live GPU tests" not in validation_text:
    raise RuntimeError("No successful native validation; no Minecraft sessions were launched")
print("Native validation passed" + (" (same jar, previous run)" if opts.reuse_validation else ""), flush=True)

for name in comparison["runs"]:
    folder = root / name
    manifest = json.loads((folder / "manifest.json").read_text())
    game = Path(manifest["game"])
    (root / "current-run").write_text(name)
    print("Starting Minecraft", name, flush=True)
    code = run(manifest["args"], game, folder / "game.log", 160, env, folder / "game-pid")
    for trace in (game / "logs").glob("mcopt-presentation-*.log"):
        shutil.copy2(trace, folder / trace.name)
    if code or "PACING_BENCH PASS" not in (folder / "game.log").read_text():
        raise RuntimeError(f"{name}: game did not complete; stopping comparison")
    with (folder / "analysis.log").open("x") as log:
        analysis = subprocess.run([sys.executable, str(Path(__file__).with_name("pacing-analyze.py")),
                                   str(folder / "measurements.json")], stdout=log, stderr=subprocess.STDOUT)
    if analysis.returncode not in (0, 2):
        raise RuntimeError(f"{name}: analyzer failed")
    summary = json.loads((folder / "summary.json").read_text())
    if not summary or not all(p["validContext"] for p in summary.values()):
        raise RuntimeError(f"{name}: focus or test context changed; stopping comparison")
    valid = sum(p["validForComparison"] for p in summary.values())
    print(f"Completed {name}: {valid}/{len(summary)} phases have complete presentation coverage", flush=True)

(root / "completed").write_text("All test processes closed normally. Check coverage and visual observations separately.\n")
print("ALL TEST WINDOWS CLOSED — normal work can resume", flush=True)
