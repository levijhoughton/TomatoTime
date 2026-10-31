#!/bin/bash
# Builds Pomodoro.app with the Xcode command-line tools (no Xcode project needed).
#   ./build.sh        build into build/Pomodoro.app
#   ./build.sh run    build, then launch it
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Pomodoro.app
rm -rf build
mkdir -p "$APP/Contents/MacOS"

swiftc -O -parse-as-library -swift-version 5 \
  -o "$APP/Contents/MacOS/Pomodoro" Pomodoro.swift

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Pomodoro</string>
  <key>CFBundleExecutable</key><string>Pomodoro</string>
  <key>CFBundleIdentifier</key><string>local.pomodoro.menubar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Pomodoro pauses Music and Spotify when a timer goes off.</string>
</dict>
</plist>
EOF

# Ad-hoc sign so macOS keeps the notification and automation permissions attached to it.
codesign --force --sign - "$APP"

echo "Built $APP"
[ "${1:-}" = "run" ] && open "$APP"
exit 0
