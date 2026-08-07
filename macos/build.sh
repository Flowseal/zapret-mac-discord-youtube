#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
BUILD="$ROOT/build/macos"
DIST="$ROOT/dist"
APP="$BUILD/ZapretMac.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
SDK=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)
SWIFTC=$(/usr/bin/xcrun -f swiftc)
CLANG=$(/usr/bin/xcrun -f clang)

/bin/rm -rf "$BUILD"
/bin/mkdir -p "$MACOS" "$RESOURCES" "$DIST"
/usr/bin/make -C "$ROOT/nfq" clean mac CC="$CLANG" SDKROOT="$SDK"
"$SWIFTC" -O -parse-as-library -sdk "$SDK" -target x86_64-apple-macos14.0 -framework AppKit "$ROOT/macos/App/ZapretMacApp.swift" -o "$BUILD/ZapretMac-x86_64"
"$SWIFTC" -O -parse-as-library -sdk "$SDK" -target arm64-apple-macos14.0 -framework AppKit "$ROOT/macos/App/ZapretMacApp.swift" -o "$BUILD/ZapretMac-arm64"
/usr/bin/lipo -create "$BUILD/ZapretMac-x86_64" "$BUILD/ZapretMac-arm64" -output "$MACOS/ZapretMac"
/bin/cp "$ROOT/macos/Info.plist" "$CONTENTS/Info.plist"
/usr/bin/ditto "$ROOT/macos/Payload" "$RESOURCES/Payload"
/bin/cp "$ROOT/nfq/utunws" "$RESOURCES/Payload/bin/utunws"
/bin/chmod 755 "$MACOS/ZapretMac" "$RESOURCES/Payload/bin/utunws" "$RESOURCES/Payload/install.sh" "$RESOURCES/Payload/run.sh" "$RESOURCES/Payload/restart.sh" "$RESOURCES/Payload/stop.sh" "$RESOURCES/Payload/watchdog.sh"
/usr/bin/codesign --force --deep --sign - "$APP"
/bin/rm -f "$DIST/ZapretMac-macOS-universal.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/ZapretMac-macOS-universal.zip"
/usr/bin/file "$MACOS/ZapretMac" "$RESOURCES/Payload/bin/utunws"
/usr/bin/codesign --verify --deep --strict "$APP"
