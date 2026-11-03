import hashlib
from pathlib import Path
import re

root = Path(__file__).resolve().parents[2]
source = (root / "macos/App/ZapretMacApp.swift").read_text()
# Remove only the backend feature sections; all original UI and update code must match.
upstream = re.sub(r"^#if ZAPRET_CONTROL\n.*?^#endif\n", "", source, flags=re.M | re.S)
upstream = upstream.replace("arguments: [String], useControl: Bool = true, completion:",
                            "arguments: [String], completion:")
normalized = "\n".join(line for line in upstream.splitlines() if line.strip())
expected = (root / "macos/Tests/upstream-app.sha256").read_text().strip()
assert hashlib.sha256(normalized.encode()).hexdigest() == expected, "Upstream UI or unrelated behavior changed"
probe = (root / "macos/Control/Probe.swift").read_text()
assert "CommandLine.arguments.count == 1" in probe and "callZapretControl(.ping)" in probe
assert "controlUserID" not in (root / "macos/Control/Protocol.swift").read_text()
print("PASS: upstream UI/update code unchanged; diagnostics read-only; no fixed account")
