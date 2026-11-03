"""Check source and expanded release payloads for this build host's identifiers."""
import getpass
from pathlib import Path
import socket
import sys

root = Path(__file__).resolve().parents[2]
markers = [str(Path.home()), getpass.getuser(), socket.gethostname()]
needles = [value.encode().lower() for value in markers if len(value) >= 4]
targets = []
for path in root.rglob("*"):
    if not path.is_file(): continue
    relative = path.relative_to(root)
    if any(part in {".git", ".DS_Store", "__pycache__", "dist"} for part in relative.parts): continue
    # Archives are compressed; validate their uncompressed build roots and scripts below.
    if relative.parts[0] == "build" and not any(part in {
        "package-root", "rollback-root", "package-scripts", "rollback-scripts"
    } for part in relative.parts): continue
    targets.append(path)
failures = []
for path in targets:
    data = path.read_bytes().lower()
    if any(needle in data for needle in needles): failures.append(str(path.relative_to(root)))
if failures:
    print("Host-specific identifiers found in: " + ", ".join(failures))
    sys.exit(1)
print(f"PASS: {len(targets)} source/payload files contain no current username, home path or host name")
