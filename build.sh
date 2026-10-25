#!/bin/bash
# Builds LyricLock.app with just the Xcode Command Line Tools (no Xcode project needed).
set -euo pipefail
cd "$(dirname "$0")"

APP="build/LyricLock.app"
ARCH="$(uname -m)"

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "-> Compiling for ${ARCH}..."
swiftc -O -parse-as-library \
  -target "${ARCH}-apple-macos14.0" \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/LyricLock"

echo "-> Adding app icon..."
iconutil -c icns Assets/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>LyricLock</string>
  <key>CFBundleDisplayName</key><string>LyricLock</string>
  <key>CFBundleIdentifier</key><string>local.lyriclock</string>
  <key>CFBundleExecutable</key><string>LyricLock</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.4</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "-> Signing (ad-hoc)..."
codesign --force --deep --sign - "$APP"

echo "Done: built ${APP}"
echo "  Move it to /Applications and open it:  mv ${APP} /Applications/ && open /Applications/LyricLock.app"
