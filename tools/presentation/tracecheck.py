#!/usr/bin/env python3
"""Exercise abrupt termination and log preservation without touching the display."""
import pathlib, subprocess, sys, tempfile, time
binary = pathlib.Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="mcopt-tracecheck-") as temp:
    log = pathlib.Path(temp) / "trace.log"
    subprocess.run([binary, "--disabled"], check=True)
    assert not log.exists()
    child = subprocess.Popen([binary, log])
    try:
        until = time.monotonic() + 5
        while time.monotonic() < until:
            text = log.read_text() if log.exists() else ""
            if "stage=test.deliberately-stuck" in text:
                break
            time.sleep(.05)
        else:
            raise AssertionError("No background stall snapshot")
        child.kill()
        child.wait(timeout=5)
    finally:
        if child.poll() is None:
            child.kill(); child.wait(timeout=5)
    before = log.read_bytes()
    text = before.decode()
    assert "test.transition.before" in text
    assert "value=42" in text
    records = [line for line in text.splitlines() if line.startswith("seq=")]
    assert len(records) == 128
    assert [int(line.split()[0][4:]) for line in records] == list(range(174, 302))
    assert (log.stat().st_mode & 0o777) == 0o600
    assert subprocess.run([binary, log]).returncode == 3
    assert log.read_bytes() == before, "Existing evidence was overwritten"
    assert subprocess.run([binary, log / "missing"]).returncode == 4
    print("PASS: disabled path, stall ring ordering, SIGKILL preservation, exclusive creation, open failure")
