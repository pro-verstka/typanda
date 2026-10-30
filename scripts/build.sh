#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Typanda"
APP_VERSION="1.2.0"
APP_BUILD="3"

BUILD_DIR="$PWD/build"
APP="$BUILD_DIR/$APP_NAME.app"
MODULE_CACHE="$BUILD_DIR/module-cache"

rm -rf "$APP" "$MODULE_CACHE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$MODULE_CACHE"

export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFT_MODULECACHE_PATH="$MODULE_CACHE"

xcrun --sdk macosx swiftc -O -parse-as-library -swift-version 5 \
    -target arm64-apple-macos26.0 \
    -o "$APP/Contents/MacOS/$APP_NAME" \
    Sources/*.swift

xcrun actool AppIcon.icon --compile "$APP/Contents/Resources" --app-icon AppIcon --platform macosx \
    --minimum-deployment-target 26.0 --target-device mac \
    --output-partial-info-plist "$BUILD_DIR/AppIcon.plist" >/dev/null

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.p1rate.${APP_NAME}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleVersion</key>
    <string>${APP_BUILD}</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$APP_NAME Developer"; then
    codesign --force --sign "$APP_NAME Developer" "$APP"
else
    codesign --force --sign - "$APP"
fi

"$APP/Contents/MacOS/$APP_NAME" --selftest

echo "Built: $APP"
