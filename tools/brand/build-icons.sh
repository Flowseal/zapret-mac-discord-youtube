#!/bin/sh
# Rebuilds the app icons from docs/brand/*.svg:
#   macos/AppIcon.icns                      (16…1024, @1x/@2x)
#   windows/src/Nimbus/Assets/nimbus.ico    (16…256, PNG-compressed entries)
# Needs Google Chrome/Chromium (headless SVG rasteriser) and python3 + Pillow.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
CHROME=${CHROME:-$(command -v google-chrome || command -v chromium || command -v chromium-browser)}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
render() { # svg size out.png
  printf '<html><body style="margin:0;background:transparent"><img src="file://%s" width="%s" height="%s"></body></html>' "$1" "$2" "$2" > "$TMP/page.html"
  "$CHROME" --headless=new --no-sandbox --disable-gpu --hide-scrollbars --allow-file-access-from-files \
    --default-background-color=00000000 --force-device-scale-factor=1 --window-size="$2,$2" \
    --screenshot="$3" "file://$TMP/page.html" >/dev/null 2>&1
}
for s in 16 32 64 128 256 512 1024; do render "$ROOT/docs/brand/app-icon-macos.svg" "$s" "$TMP/mac-$s.png"; done
for s in 16 20 24 32 40 48 64 256; do render "$ROOT/docs/brand/app-icon-windows.svg" "$s" "$TMP/win-$s.png"; done
python3 "$ROOT/tools/brand/pack-icons.py" "$TMP" "$ROOT/macos/AppIcon.icns" "$ROOT/windows/src/Nimbus/Assets/nimbus.ico"
