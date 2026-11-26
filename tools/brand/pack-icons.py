#!/usr/bin/env python3
"""Packs rendered PNGs into an Apple .icns and a Windows .ico (no iconutil needed)."""
import struct, sys, io
from pathlib import Path
from PIL import Image

src, icns_out, ico_out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])

def png(path):
    return path.read_bytes()

# icns: OSType -> pixel size (PNG payloads, supported since 10.7)
ICNS = [("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128), ("ic08", 256), ("ic09", 512), ("ic10", 1024),
        ("ic11", 32), ("ic12", 64), ("ic13", 256), ("ic14", 512)]
chunks = b""
for ostype, size in ICNS:
    data = png(src / f"mac-{size}.png")
    chunks += ostype.encode() + struct.pack(">I", len(data) + 8) + data
icns_out.write_bytes(b"icns" + struct.pack(">I", len(chunks) + 8) + chunks)

# ico: PNG entries (Vista+), 256 is stored as 0 in the directory
sizes = [16, 20, 24, 32, 40, 48, 64, 256]
blobs = []
for s in sizes:
    im = Image.open(src / f"win-{s}.png").convert("RGBA")
    buf = io.BytesIO(); im.save(buf, "PNG", optimize=True); blobs.append(buf.getvalue())
header = struct.pack("<HHH", 0, 1, len(sizes))
offset = 6 + 16 * len(sizes)
entries = b""
for s, b in zip(sizes, blobs):
    entries += struct.pack("<BBBBHHII", s % 256, s % 256, 0, 0, 1, 32, len(b), offset)
    offset += len(b)
ico_out.write_bytes(header + entries + b"".join(blobs))
print("wrote", icns_out, icns_out.stat().st_size, "bytes;", ico_out, ico_out.stat().st_size, "bytes")
