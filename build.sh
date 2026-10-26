#!/bin/bash
# Builds Repeat.app into ~/Applications (rerun after editing main.swift).
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/Repeat.app"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -target arm64-apple-macos13 -o "$APP/Contents/MacOS/Repeat" "$SRC/main.swift"

# Icon: draw it at 1024×1024 (icon.swift), then scale down into an .icns.
swift "$SRC/icon.swift" "$WORK/icon.png"
ICONSET="$WORK/Repeat.iconset"
mkdir "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$WORK/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$WORK/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Repeat.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Repeat</string>
  <key>CFBundleDisplayName</key><string>Repeat</string>
  <key>CFBundleIdentifier</key><string>local.repeat.app</string>
  <key>CFBundleExecutable</key><string>Repeat</string>
  <key>CFBundleIconFile</key><string>Repeat</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>5.7</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Repeat 录制</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>CFBundleTypeIconFile</key><string>Repeat</string>
      <key>LSItemContentTypes</key><array><string>local.repeat.recording</string></array>
    </dict>
  </array>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>local.repeat.recording</string>
      <key>UTTypeDescription</key><string>Repeat 录制</string>
      <key>UTTypeIconFile</key><string>Repeat</string>
      <key>UTTypeConformsTo</key><array><string>public.plain-text</string></array>
      <key>UTTypeTagSpecification</key>
      <dict><key>public.filename-extension</key><array><string>repeat</string></array></dict>
    </dict>
  </array>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

# Stable designated requirement: privacy grants (Accessibility / Input Monitoring) are tied to it,
# so rebuilding does not invalidate them (plain ad-hoc signing pins them to the binary hash).
codesign --force --sign - -r='designated => identifier "local.repeat.app"' "$APP"
# Register the .repeat document type so Finder double-click opens recordings in this app.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "Built $APP"
