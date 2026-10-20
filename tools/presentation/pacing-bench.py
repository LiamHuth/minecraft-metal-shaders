"""Pacing test; uses cached Prism dependencies and a disposable offline world."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import zipfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("jar", type=Path)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--java-home", type=Path, required=True)
parser.add_argument("--prepare-only", action="store_true")
parser.add_argument("--suite", choices=["clock", "presentation", "fullscreen"], default="clock")
parser.add_argument("--policy", choices=["legacy", "ready", "precise"], default="legacy",
                    help="Fixed startup policy for the fullscreen suite; no live toggles")
parser.add_argument("--vsync", choices=["on", "off"], default="on")
parser.add_argument("--motion", choices=["none", "append", "only"], default="none",
                    help="Fullscreen visual tearing check; append after timings or run alone")
opts = parser.parse_args()
if opts.vsync == "off" and (opts.suite != "fullscreen" or opts.policy != "legacy"):
    parser.error("VSync-off control requires fullscreen legacy; candidate still requires VSync")
if opts.motion != "none" and opts.suite != "fullscreen":
    parser.error("Motion check requires a fixed fullscreen session")
jar = opts.jar.resolve()
output = opts.output.resolve()
output.mkdir(parents=True, exist_ok=False)  # preserve previous measurements
prism = Path.home() / "Library/Application Support/PrismLauncher"
game = Path(tempfile.mkdtemp(prefix="mcopt-pacing-ab-", dir="/private/tmp"))
(output / "game-path").write_text(str(game))
java = opts.java_home / "bin"
cp = []
for uid, version in [("org.lwjgl3", "3.4.3"), ("net.minecraft", "26.3"), ("net.fabricmc.fabric-loader", "0.19.5")]:
    meta = json.loads((prism / f"meta/{uid}/{version}.json").read_text())
    for lib in meta.get("libraries", []) + ([meta["mainJar"]] if "mainJar" in meta else []):
        allowed = not lib.get("rules")
        for rule in lib.get("rules", []):
            os_rule = rule.get("os", {})
            if os_rule.get("name", "osx-arm64") == "osx-arm64" and os_rule.get("arch", "aarch64") in ["aarch64", "arm64"]:
                allowed = rule["action"] == "allow"
        if not allowed:
            continue
        group, artifact, ver, *classifier = lib["name"].split(":")
        filename = artifact + "-" + ver + ("-" + classifier[0] if classifier else "") + ".jar"
        path = prism / "libraries" / group.replace(".", "/") / artifact / ver / filename
        if not path.exists():
            raise FileNotFoundError(path)
        cp.append(str(path))
(game / "mods").mkdir()
(game / "config").mkdir()
shutil.copy2(jar, game / "mods")
(game / "options.txt").write_text(
    f"pauseOnLostFocus:false\nenableVsync:{str(opts.vsync == 'on').lower()}\nmaxFps:120\n"
    f"fullscreen:{str(opts.suite == 'fullscreen').lower()}\nexclusiveFullscreen:false\n"
    "renderDistance:4\nsimulationDistance:5\nlang:en_us\nonboardAccessibility:false\n")
(game / "config/mcopt.properties").write_text(
    "mcopt.shade=true\nmcopt.shade.hdrMode=scene\n"
    f"mcopt.shade.output={900 if opts.suite == 'fullscreen' else 2160}\n")
classes = output / "classes"
classes.mkdir(exist_ok=True)
sources = [Path(__file__).with_name(name) for name in ["PacingBench.java", "PollTimingMixin.java", "GpuLoad.java", "GpuLoadMixin.java", "BenchContext.java"]]
subprocess.run([str(java / "javac"), "-proc:none", "-classpath", ":".join(cp + [str(jar)]),
                "-d", str(classes), *map(str, sources)], check=True)
with zipfile.ZipFile(game / "mods/pacing-bench.jar", "w") as archive:
    for file in classes.rglob("*.class"):
        archive.write(file, str(file.relative_to(classes)))
    archive.writestr("fabric.mod.json", json.dumps({
        "schemaVersion": 1, "id": "pacing-bench", "version": "1", "environment": "client",
        "entrypoints": {"client": ["mcopt.pacingbench.PacingBench"]}, "mixins": ["pacing-bench.mixins.json"]}))
    archive.writestr("pacing-bench.mixins.json", json.dumps({
        "required": True, "package": "mcopt.pacingbench.mixin", "compatibilityLevel": "JAVA_25",
        "client": ["PollTimingMixin", "GpuLoadMixin"]}))
load_library = output / "libpacingload.dylib"
subprocess.run(["clang", "-fno-objc-arc", "-O2", "-Wall", "-dynamiclib", "-mmacosx-version-min=15.0",
    "-I", str(Path(__file__).resolve().parents[2] / "metal/src/main/native"),
    "-framework", "AppKit", "-framework", "Metal", "-framework", "QuartzCore",
    str(Path(__file__).with_name("load.m")), str(Path(__file__).with_name("context.m")),
    "-o", str(load_library)], check=True)
args = [
    str(java / "java"), "-XstartOnFirstThread", "-Xmx2G", "--enable-native-access=ALL-UNNAMED",
    "-Dmcopt.shade=true", "-Dmcopt.shade.diag=false",
    f"-Dmcopt.metal.displayLink={str(opts.suite == 'fullscreen' and opts.policy != 'legacy').lower()}",
    f"-Dmcopt.metal.displayLink.presentation={opts.policy if opts.policy != 'legacy' else 'ready'}", "-Dmcopt.metal.displayLink.queue=0",
    "-Dmcopt.metal.gpuTimes=true", "-Dmcopt.metal.latency=true",
    f"-Dmcopt.bench.output={output / 'measurements.json'}",
    f"-Dmcopt.bench.loadLibrary={load_library}",
    f"-Dmcopt.bench.suite={opts.suite}",
    f"-Dmcopt.bench.policy={opts.policy}",
    f"-Dmcopt.bench.vsync={str(opts.vsync == 'on').lower()}",
    f"-Dmcopt.bench.motion={opts.motion}",
    "-classpath", ":".join(cp), "net.fabricmc.loader.impl.launch.knot.KnotClient",
    "--username", "PacingTest", "--uuid", "00000000-0000-0000-0000-000000000001",
    "--accessToken", "0", "--version", "26.3", "--gameDir", str(game),
    "--assetsDir", str(prism / "assets"), "--assetIndex", "34", "--width", "640", "--height", "400"]
if opts.suite == "fullscreen":
    args.append("--fullscreen")
if opts.vsync == "off":
    # Shade.init otherwise enables native display sync even when the game's
    # VSync option is off. Override only in this explicit unsynchronized control.
    args.insert(1, "-Dmcopt.metal.paceSync=false")
(output / "manifest.json").write_text(json.dumps({
    "jar": str(jar), "sha256": hashlib.sha256(jar.read_bytes()).hexdigest(),
    "game": str(game), "args": args, "metalValidation": False,
    "suite": opts.suite,
    "policy": opts.policy if opts.suite == "fullscreen" else "mixed",
    "vsync": opts.vsync, "motion": opts.motion,
    "motionProtocol": "Visual check only: striped wall, constant-speed yaw +/-30 degrees per four seconds (turns at ends), 120 FPS cap with GPU work changing every 237ms. Software timestamps do not detect tearing.",
    "protocol": ("Fullscreen HDR from startup; fixed policy per process; 900p output; 50/60/120 light and 120 time-based varying GPU load; 3s settle + 10s sample"
        if opts.suite == "fullscreen" else "Windowed HDR; 50/60/120 light and 120 varying GPU load; legacy/ready/duration/duration+queue2/duration+queue3; reverse loaded repeat; 3s settle + 8s sample"
        if opts.suite == "presentation" else "Windowed HDR 1280x800; 50 FPS ABBA, 60 on/off, 120 off/on; 4s settle + 12s sample; variable GPU-load 120 FPS ABBA"),
}, indent=2) + "\n")
if opts.prepare_only:
    print("Prepared without launching:", game)
    raise SystemExit(0)
# Do not profile with the Metal validation layer; this is a cadence measurement.
env = {k: v for k, v in os.environ.items() if not k.startswith("MTL_DEBUG")}
with (output / "game.log").open("w") as log:
    process = subprocess.Popen(args, cwd=game, stdout=log, stderr=subprocess.STDOUT, env=env)
    (output / "game-pid").write_text(str(process.pid))
    try:
        code = process.wait(timeout=480 if opts.suite == "presentation" else 330)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)
        raise
for trace in (game / "logs").glob("mcopt-presentation-*.log"):
    shutil.copy2(trace, output / trace.name)
print("Game exit:", code, "profile:", game)
if code or "PACING_BENCH PASS" not in (output / "game.log").read_text():
    raise RuntimeError("Pacing test did not finish; inspect game.log")
print("Measurements:", output / "measurements.json")
