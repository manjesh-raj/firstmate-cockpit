#!/usr/bin/env bash
# Build Manjesh Grand Line.app: a plain macOS app-bundle wrapper around the
# native Swift cockpit (native/, SwiftTerm-based). No notarization, but the
# bundle is codesigned with a stable local identity when one is available -
# see "Local signing" below and native/README.md's "Local signing setup" section.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Manjesh Grand Line.app"
DIST_DIR="../dist"
APP_DIR="$DIST_DIR/$APP_NAME"
EXECUTABLE_NAME="FirstmateCockpit"
BUNDLE_ID="com.firstmate.cockpit.native"
VERSION="0.1.0"
ICON_SRC="../assets/icon.icns"
SIGNING_IDENTITY="Firstmate Cockpit Local Dev"

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

# SRE Lead's read-only kubectl MCP tool (SRELead.swift resolves it via
# Bundle.main.resourceURL first, falling back to the source tree for
# swift run/swift build dev flows).
if [ -f "Scripts/sre_kubectl_mcp.py" ]; then
  cp "Scripts/sre_kubectl_mcp.py" "$APP_DIR/Contents/Resources/sre_kubectl_mcp.py"
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Manjesh Grand Line</string>
    <key>CFBundleDisplayName</key>
    <string>Manjesh Grand Line</string>
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
    <key>NSMicrophoneUsageDescription</key>
    <string>Dictation uses your microphone to capture speech while you hold Right Option, so it can transcribe and paste it at your cursor.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Dictation uses Speech Recognition (on-device when available) to turn what you say into text.</string>
</dict>
</plist>
PLIST

if security find-identity -v -p codesigning | grep -q "$SIGNING_IDENTITY"; then
  echo "Signing with local identity \"$SIGNING_IDENTITY\"…"
  codesign --force --sign "$SIGNING_IDENTITY" --identifier "$BUNDLE_ID" "$APP_DIR"
else
  echo "⚠️  No \"$SIGNING_IDENTITY\" codesigning identity found - building unsigned."
  echo "    Saved Keychain items (SSH keys/passphrases) may stop being readable"
  echo "    after a future rebuild, since an unsigned/ad-hoc binary gets a new"
  echo "    code identity on every rebuild. See native/README.md's"
  echo "    \"Local signing setup\" section to create this identity once per machine."
fi

echo ""
echo "✓ Built: $(cd "$DIST_DIR" && pwd)/$APP_NAME"
echo "  Open with:  open $APP_DIR"
