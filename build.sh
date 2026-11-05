#!/bin/bash
# Build Shapeshift.app (universal: Apple silicon + Intel).
#   ./build.sh             → build/Shapeshift.app
#   ./build.sh --install   → also copy to /Applications and relaunch
#   ./build.sh --dmg       → also make build/Shapeshift-<version>.dmg for sharing
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(cat VERSION 2>/dev/null || echo 1.0.0)"
APP="build/Shapeshift.app"

echo "▸ Compiling Shapeshift $VERSION (arm64 + x86_64)…"
swift build -c release --arch arm64 --arch x86_64 2>&1 | grep -E "error:|Build complete" || true
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Shapeshift"
[ -x "$BIN" ] || { echo "Build failed"; exit 1; }

echo "▸ Assembling app bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Shapeshift"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Shapeshift</string>
  <key>CFBundleDisplayName</key><string>Shapeshift</string>
  <key>CFBundleIdentifier</key><string>io.github.shapeshift</string>
  <key>CFBundleExecutable</key><string>Shapeshift</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Free and open source (MIT).</string>
  <key>NSAppleEventsUsageDescription</key><string>Shapeshift reads the files selected in Finder when you press ⌃⌥Space.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Shapeshift transcribes audio and video into subtitles on your Mac.</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "✓ Built $APP"

if [ "${1:-}" = "--install" ]; then
  pkill -x Shapeshift 2>/dev/null && sleep 1 || true
  rm -rf /Applications/Shapeshift.app
  cp -R "$APP" /Applications/
  open /Applications/Shapeshift.app
  echo "✓ Installed and launched /Applications/Shapeshift.app"
fi

if [ "${1:-}" = "--dmg" ]; then
  DMG="build/Shapeshift-$VERSION.dmg"
  STAGE="build/dmg"
  rm -rf "$STAGE" "$DMG"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  cat > "$STAGE/READ ME FIRST.txt" <<TXT
Shapeshift $VERSION is a free, offline file converter for your Mac.

1. Drag Shapeshift onto the Applications folder.
2. The first time, macOS will block it because it isn't from the App Store.
   Open System Settings → Privacy & Security, scroll down, and click "Open Anyway".
   (Or run this in Terminal:  xattr -dr com.apple.quarantine /Applications/Shapeshift.app)
3. For audio and video, install ffmpeg:   brew install ffmpeg
   (Homebrew is free and available at https://brew.sh)

How to use it: drag any file, tap Shift (convert), Command (tools) or Control (actions), then drop it on a wedge.
TXT
  hdiutil create -volname "Shapeshift" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  rm -rf "$STAGE"
  (cd build && ditto -c -k --keepParent Shapeshift.app "Shapeshift-$VERSION.zip")
  echo "✓ Made $DMG and build/Shapeshift-$VERSION.zip"
fi
