#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build -c release
./scripts/export-icon.sh
mkdir -p dist/Recorder.app/Contents/Resources
cp assets/Recorder.icns dist/Recorder.app/Contents/Resources/Recorder.icns
mkdir -p dist/Recorder.app/Contents/MacOS
cp .build/release/Recorder dist/Recorder.app/Contents/MacOS/Recorder
cat > dist/Recorder.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Recorder</string>
<key>CFBundleIdentifier</key><string>local.recorder.app</string>
<key>CFBundleIconFile</key><string>Recorder</string>
<key>CFBundleName</key><string>Recorder</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSCameraUsageDescription</key><string>Record your webcam beside your screen.</string>
<key>NSMicrophoneUsageDescription</key><string>Record your voice with your video.</string>
</dict></plist>
PLIST
codesign --force --sign - dist/Recorder.app
