#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="output/DentalViewer.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" output/module-cache
task_arch="$(uname -m)"
swiftc -swift-version 5 -target "${task_arch}-apple-macosx13.0" -O -module-cache-path output/module-cache Sources/*.swift \
  -framework AppKit -framework SwiftUI -framework Metal -framework MetalKit \
  -o "$app/Contents/MacOS/DentalViewer"
rm -rf "$app/Contents/Resources/Segmentation"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>DentalViewer</string>
<key>CFBundleDisplayName</key><string>DentalViewer</string>
<key>CFBundleExecutable</key><string>DentalViewer</string>
<key>CFBundleIdentifier</key><string>local.dentalviewer.macos</string>
<key>CFBundleVersion</key><string>12</string>
<key>CFBundleShortVersionString</key><string>0.5.7</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$app"
echo "Aplicación generada: $app"
