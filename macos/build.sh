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
SDK_VERSION=$(/usr/bin/xcrun --sdk macosx --show-sdk-version)
SWIFTC=$(/usr/bin/xcrun -f swiftc)
CLANG=$(/usr/bin/xcrun -f clang)
APP_NAME=ZapretMac

SWIFT_SOURCES=$(find "$ROOT/macos/App" -name '*.swift' | sort)
MACOS_MIN=${MACOS_MIN:-14.0}
SWIFT_FLAGS="-O -parse-as-library -swift-version 5 -sdk $SDK -framework AppKit -framework SwiftUI"
LINKER_FLAGS="-Xlinker -platform_version -Xlinker macos -Xlinker ${MACOS_MIN} -Xlinker ${SDK_VERSION}"

/bin/rm -rf "$BUILD"
/bin/mkdir -p "$MACOS" "$RESOURCES" "$DIST"
/usr/bin/make -C "$ROOT/nfq" clean mac CC="$CLANG" SDKROOT="$SDK"
"$SWIFTC" $SWIFT_FLAGS $LINKER_FLAGS -target "x86_64-apple-macos${MACOS_MIN}" $SWIFT_SOURCES -o "$BUILD/${APP_NAME}-x86_64"
"$SWIFTC" $SWIFT_FLAGS $LINKER_FLAGS -target "arm64-apple-macos${MACOS_MIN}" $SWIFT_SOURCES -o "$BUILD/${APP_NAME}-arm64"
/usr/bin/lipo -create "$BUILD/${APP_NAME}-x86_64" "$BUILD/${APP_NAME}-arm64" -output "$MACOS/$APP_NAME"
/bin/cp "$ROOT/macos/Info.plist" "$CONTENTS/Info.plist"
/bin/cp "$ROOT/macos/AppIcon.icns" "$RESOURCES/AppIcon.icns"
/usr/bin/ditto "$ROOT/macos/Payload" "$RESOURCES/Payload"
/bin/cp "$ROOT/nfq/utunws" "$RESOURCES/Payload/bin/utunws"
/bin/chmod 755 "$MACOS/$APP_NAME" "$RESOURCES/Payload/bin/utunws" "$RESOURCES/Payload/install.sh" "$RESOURCES/Payload/run.sh" "$RESOURCES/Payload/restart.sh" "$RESOURCES/Payload/stop.sh" "$RESOURCES/Payload/test-strategies.sh" "$RESOURCES/Payload/update-app.sh" "$RESOURCES/Payload/watchdog.sh"
/usr/bin/codesign --force --deep --sign - "$APP"
/bin/rm -f "$DIST/ZapretMac-macOS-universal.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/ZapretMac-macOS-universal.zip"
/usr/bin/file "$MACOS/$APP_NAME" "$RESOURCES/Payload/bin/utunws"
/usr/bin/codesign --verify --deep --strict "$APP"
