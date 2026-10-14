#!/bin/bash
# Builds Speakeys.app next to this script.
#   ./build.sh            build only
#   ./build.sh --install  build, copy to /Applications and launch
set -euo pipefail
cd "$(dirname "$0")"

APP=Speakeys.app
VERSION=1.2.0
# Override with your own identifier: BUNDLE_ID=com.yourname.speakeys ./build.sh
BUNDLE_ID="${BUNDLE_ID:-com.akin.speakeys}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 main.swift -o "$APP/Contents/MacOS/Speakeys" \
  -framework AppKit -framework AVFoundation -framework Speech -framework Carbon -framework ServiceManagement

swift make_icon.swift "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleName</key><string>Speakeys</string>
  <key>CFBundleDisplayName</key><string>Speakeys</string>
  <key>CFBundleExecutable</key><string>Speakeys</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 Hakan Akin. MIT License.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Speakeys listens only while you're dictating, to turn your speech into text. Nothing is recorded.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Speakeys turns what you say into text while you're dictating.</string>
</dict>
</plist>
PLIST

# Sign with a stable identity when available so macOS keeps the
# Accessibility permission across rebuilds; otherwise fall back to ad-hoc.
IDENTITY=$(security find-identity -v -p codesigning | grep -m1 "Apple Development" | awk '{print $2}' || true)
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $(pwd)/$APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Speakeys 2>/dev/null || true
  rm -rf "/Applications/$APP"
  cp -R "$APP" /Applications/
  open "/Applications/$APP"
  echo "Installed /Applications/$APP"
fi
