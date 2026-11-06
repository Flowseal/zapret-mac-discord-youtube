"""Exercise the real controller with isolated launchctl/network command doubles."""
import os
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / "Control/control.sh").read_text()
with tempfile.TemporaryDirectory(prefix="zapret-control-test-") as directory:
    root = Path(directory)
    state = root / "state"
    state.mkdir()
    base = root / "payload"
    base.mkdir()
    (base / "engine.log").write_text("test diagnostic\n")
    fake = root / "fake.py"
    fake.write_text('''#!/usr/bin/python3
import sys
from pathlib import Path
s = Path(__file__).parent / 'state'
command, args = sys.argv[1], sys.argv[2:]
with (s/'calls').open('a') as f: f.write(command+' '+' '.join(args)+'\\n')
def has(name): return (s/name).exists()
def put(name): (s/name).touch()
if command == 'id': print('0')
elif command == 'sysctl':
 if args[0] == '-n': print('75000')
elif command == 'pgrep': sys.exit(0 if has('running') else 1)
elif command == 'ifconfig': sys.exit(0 if has('running') else 1)
elif command == 'launchctl':
 if args[0] == 'print': sys.exit(0 if has('loaded') else 1)
 if args[0] == 'bootstrap':
  if has('fail-bootstrap'): sys.exit(1)
  put('loaded')
 if args[0] == 'kickstart':
  if has('fail-kickstart'): sys.exit(1)
  if not has('fail-engine'): put('running')
elif command == 'sleep': pass
else: sys.exit(99)
''')
    fake.chmod(0o755)
    controller = source.replace("BASE='/Library/Application Support/ZapretMac'", f"BASE='{base}'")
    controller = controller.replace("KEEPINIT='/var/db/zapret-macos.keepinit'", f"KEEPINIT='{state}/keepinit'")
    for command in ["/usr/bin/id", "/usr/bin/pgrep", "/sbin/ifconfig", "/usr/sbin/sysctl", "/bin/launchctl", "/bin/sleep"]:
        controller = controller.replace(command, f"{fake} {Path(command).name}")
    script = root / "control.sh"
    script.write_text(controller)
    (base / "stop.sh").write_text(f'''#!/bin/sh
echo cleanup >> '{state}/calls'
rm -f '{state}/running' '{state}/loaded' '{state}/keepinit'
''')

    def run(action):
        return subprocess.run(["/bin/sh", str(script), action], capture_output=True, text=True, timeout=10)

    def reset():
        for p in state.iterdir(): p.unlink()

    result = run("start")
    assert result.returncode == 0, result.stderr
    assert (state / "running").exists()
    assert (state / "keepinit").read_text().strip() == "75000"
    calls = (state / "calls").read_text()
    assert "launchctl bootstrap" in calls and "launchctl kickstart" in calls
    (state / "calls").write_text("")
    assert run("start").returncode == 0
    assert "kickstart" not in (state / "calls").read_text(), "start must be idempotent"
    assert run("restart").returncode == 0
    assert "kickstart" in (state / "calls").read_text()
    assert run("stop").returncode == 0
    assert not (state / "running").exists() and not (state / "keepinit").exists()

    for fault in ["fail-bootstrap", "fail-kickstart", "fail-engine"]:
        reset()
        (state / fault).touch()
        result = run("start")
        assert result.returncode != 0, fault
        assert "cleanup" in (state / "calls").read_text(), fault
        assert not (state / "running").exists() and not (state / "keepinit").exists(), fault

    for invalid in ["", "start; id", "../start", "stop extra", "test", "update"]:
        reset()
        result = run(invalid)
        assert result.returncode == 64, (invalid, result)
        assert (state / "calls").read_text() == "id -u\n"
    print("PASS: start, idempotent start, restart, stop, three failure cleanups, invalid input")
