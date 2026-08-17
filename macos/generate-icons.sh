#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
SRC="$ROOT/Icons/source"
ICONSET="$ROOT/AppIcon.iconset"
ICNS="$ROOT/AppIcon.icns"

/bin/mkdir -p "$ICONSET"
/bin/cp "$SRC/icon-16.png" "$ICONSET/icon_16x16.png"
/bin/cp "$SRC/icon-32.png" "$ICONSET/icon_16x16@2x.png"
/bin/cp "$SRC/icon-32.png" "$ICONSET/icon_32x32.png"
/bin/cp "$SRC/icon-64.png" "$ICONSET/icon_32x32@2x.png"
/bin/cp "$SRC/icon-128.png" "$ICONSET/icon_128x128.png"
/bin/cp "$SRC/icon-256.png" "$ICONSET/icon_128x128@2x.png"
/bin/cp "$SRC/icon-256.png" "$ICONSET/icon_256x256.png"
/bin/cp "$SRC/icon-512.png" "$ICONSET/icon_256x256@2x.png"
/bin/cp "$SRC/icon-512.png" "$ICONSET/icon_512x512.png"
/usr/bin/sips -z 1024 1024 "$SRC/icon-512.png" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
/usr/bin/iconutil -c icns "$ICONSET" -o "$ICNS"
echo "Generated $ICNS"
