#!/usr/bin/env bash
# Build New-Firstmate.app: a plain macOS app-bundle wrapper around the native
# Swift cockpit (native/, SwiftTerm-based). This is NOT the old web/WKWebView
# app - that one is dist/Firstmate.app, built by ../build_app.sh via py2app.
# The two are deliberately named and identified differently so they can't be
# confused on disk or in the Dock. No py2app, no signing, no notarization:
# this is a lightweight, unsigned, local-use bundle.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="New-Firstmate.app"
DIST_DIR="../dist"
APP_DIR="$DIST_DIR/$APP_NAME"
EXECUTABLE_NAME="FirstmateCockpit"
BUNDLE_ID="com.firstmate.cockpit.native"
VERSION="0.1.0"
ICON_SRC="../assets/icon.icns"

echo "Building $EXECUTABLE_NAME (release)…"
swift build -c release

BIN="./.build/release/$EXECUTABLE_NAME"
[ -x "$BIN" ] || { echo "build did not produce $BIN"; exit 1; }

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN" "$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"

if [ -f "$ICON_SRC" ]; then
  cp "$ICON_SRC" "$APP_DIR/Contents/Resources/icon.icns"
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>New Firstmate</string>
    <key>CFBundleDisplayName</key>
    <string>New Firstmate (Native Cockpit)</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>$EXECUTABLE_NAME</string>
    <key>CFBundleIconFile</key>
    <string>icon.icns</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <false/>
</dict>
</plist>
PLIST

echo ""
echo "✓ Built: $(cd "$DIST_DIR" && pwd)/$APP_NAME"
echo "  Open with:  open $APP_DIR"
