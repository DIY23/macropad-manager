#!/bin/bash
# Build MacroPad Manager.app (universal) and a distributable DMG.
# No Xcode required: swiftc + lipo + codesign + hdiutil only.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/MacroPad Manager.app"
VERSION="${VERSION:-1.0.0}"
SDK="$(xcrun --show-sdk-path)"
MIN_MACOS="${MIN_MACOS:-13.0}"

echo "==> cleaning"
rm -rf "$BUILD"
mkdir -p "$BUILD/bin" "$APP/Contents/MacOS" "$APP/Contents/Resources"

SOURCES=("$ROOT"/Sources/*.swift)

echo "==> compiling x86_64"
swiftc -O -parse-as-library -target "x86_64-apple-macos${MIN_MACOS}" -sdk "$SDK" \
  -o "$BUILD/bin/mpm-x86_64" "${SOURCES[@]}"

echo "==> compiling arm64"
swiftc -O -parse-as-library -target "arm64-apple-macos${MIN_MACOS}" -sdk "$SDK" \
  -o "$BUILD/bin/mpm-arm64" "${SOURCES[@]}"

echo "==> lipo"
lipo -create -output "$APP/Contents/MacOS/MacroPadManager" \
  "$BUILD/bin/mpm-x86_64" "$BUILD/bin/mpm-arm64"
chmod +x "$APP/Contents/MacOS/MacroPadManager"

echo "==> icon"
mkdir -p "$BUILD/icon.iconset"
swiftc -O -target "x86_64-apple-macos${MIN_MACOS}" -sdk "$SDK" \
  -o "$BUILD/bin/makeicon" "$ROOT/Tools/icon/main.swift"
"$BUILD/bin/makeicon" "$BUILD/icon_1024.png"
for sz in 16 32 64 128 256 512 1024; do
  sips -z $sz $sz "$BUILD/icon_1024.png" --out "$BUILD/icon.iconset/icon_${sz}x${sz}.png" >/dev/null
done
for sz in 16 32 128 256 512; do
  d=$((sz * 2))
  sips -z $d $d "$BUILD/icon_1024.png" --out "$BUILD/icon.iconset/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "$BUILD/icon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MacroPad Manager</string>
  <key>CFBundleDisplayName</key><string>MacroPad Manager</string>
  <key>CFBundleExecutable</key><string>MacroPadManager</string>
  <key>CFBundleIdentifier</key><string>com.diy23.macropad-manager</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>${MIN_MACOS}</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT licensed. Not affiliated with the hardware vendor.</string>
  <key>NSSupportsAutomaticTermination</key><false/>
</dict>
</plist>
PLIST

echo "==> codesign (ad-hoc)"
codesign --force --deep --sign - "$APP"
codesign --verify --verbose=1 "$APP" 2>&1 | tail -2

echo "==> dmg"
mkdir -p "$BUILD/dmgroot"
cp -R "$APP" "$BUILD/dmgroot/"
ln -s /Applications "$BUILD/dmgroot/Applications"
DMG="$BUILD/MacroPadManager-${VERSION}.dmg"
rm -f "$DMG"
hdiutil create -volname "MacroPad Manager" -srcfolder "$BUILD/dmgroot" \
  -ov -format UDZO "$DMG" >/dev/null

echo "==> done"
du -sh "$APP" "$DMG"
