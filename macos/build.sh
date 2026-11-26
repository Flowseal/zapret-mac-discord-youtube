#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
BUILD="$ROOT/build/macos"
DIST="$ROOT/dist"
APP="$BUILD/Nimbus.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
SDK=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)
SWIFTC=$(/usr/bin/xcrun -f swiftc)
CLANG=$(/usr/bin/xcrun -f clang)
SWIFT_SOURCES="$ROOT/macos/App/ZapretMacApp.swift $ROOT/macos/App/NimbusDesign.swift $ROOT/macos/App/NimbusHUD.swift $ROOT/macos/App/NimbusSupport.swift $ROOT/macos/App/VpnDetect.swift"
SWIFT_FLAGS="-O -parse-as-library -sdk $SDK -framework AppKit -framework SwiftUI -framework ServiceManagement -framework Security -framework CryptoKit -framework QuartzCore"

/bin/rm -rf "$BUILD"
/bin/mkdir -p "$MACOS" "$RESOURCES" "$DIST"
/usr/bin/make -C "$ROOT/nfq" clean mac CC="$CLANG" SDKROOT="$SDK"
# shellcheck disable=SC2086
"$SWIFTC" $SWIFT_FLAGS -target x86_64-apple-macos14.0 $SWIFT_SOURCES -o "$BUILD/Nimbus-x86_64"
# shellcheck disable=SC2086
"$SWIFTC" $SWIFT_FLAGS -target arm64-apple-macos14.0 $SWIFT_SOURCES -o "$BUILD/Nimbus-arm64"
/usr/bin/lipo -create "$BUILD/Nimbus-x86_64" "$BUILD/Nimbus-arm64" -output "$MACOS/Nimbus"
/bin/cp "$ROOT/macos/Info.plist" "$CONTENTS/Info.plist"
/bin/cp "$ROOT/macos/AppIcon.icns" "$RESOURCES/AppIcon.icns"
/usr/bin/ditto "$ROOT/macos/Payload" "$RESOURCES/Payload"
/bin/cp "$ROOT/nfq/utunws" "$RESOURCES/Payload/bin/utunws"
/bin/chmod 755 "$MACOS/Nimbus" "$RESOURCES/Payload/bin/utunws" "$RESOURCES/Payload/install.sh" "$RESOURCES/Payload/run.sh" "$RESOURCES/Payload/restart.sh" "$RESOURCES/Payload/stop.sh" "$RESOURCES/Payload/test-strategies.sh" "$RESOURCES/Payload/update-app.sh" "$RESOURCES/Payload/watchdog.sh" "$RESOURCES/Payload/diagnose.sh"
/usr/bin/codesign --force --deep --sign - "$APP"
/bin/rm -f "$DIST/Nimbus-macOS-universal.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/Nimbus-macOS-universal.zip"
/usr/bin/file "$MACOS/Nimbus" "$RESOURCES/Payload/bin/utunws"
/usr/bin/codesign --verify --deep --strict "$APP"
