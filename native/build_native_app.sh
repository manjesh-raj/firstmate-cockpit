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
# GL-18: derive the version from git rather than hardcoding it. `git describe`
# gives `v0.2.0` on a tagged commit and `v0.2.0-7-g1a2b3c4` seven commits later,
# which is exactly what a dev build should say. Falls back to a short SHA (or
# `0.0.0-unknown` outside a checkout) so a build never fails just because tags
# are missing.
#
# `CFBundleShortVersionString` must be a plain dotted number for Launch
# Services, so the marketing version is the tag's numeric part only, while the
# full describe string (commits-ahead + SHA + `-dirty`) goes into
# `CFBundleVersion`, which is free-form.
GIT_DESCRIBE="$(git describe --tags --dirty --always 2>/dev/null || true)"
if [ -z "$GIT_DESCRIBE" ]; then
  GIT_DESCRIBE="0.0.0-unknown"
fi
# Strip a leading `v` and keep the leading dotted-number run for the short
# version; anything without one (a bare SHA) falls back to 0.0.0.
SHORT_VERSION="$(printf '%s' "${GIT_DESCRIBE#v}" | sed -n 's/^\([0-9][0-9.]*\).*/\1/p')"
if [ -z "$SHORT_VERSION" ]; then
  SHORT_VERSION="0.0.0"
fi
VERSION="$SHORT_VERSION"
BUILD_VERSION="${GIT_DESCRIBE#v}"
ICON_SRC="../assets/icon.icns"
SIGNING_IDENTITY="Firstmate Cockpit Local Dev"

echo "Building $EXECUTABLE_NAME (release) - version $VERSION (build $BUILD_VERSION)…"
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
    <string>$BUILD_VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <false/>
    <!-- GL-05: Launch Services activates the running copy instead of starting
         a second process. Two instances share one set of JSON stores (all
         last-writer-wins) and one Shift git working tree, so the second one
         silently discards the first's saves. `SingleInstanceGuard` covers the
         paths that bypass Launch Services (`open -n`, an unbundled binary). -->
    <key>LSMultipleInstancesProhibited</key>
    <true/>
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
