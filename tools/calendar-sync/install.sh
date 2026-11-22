#!/bin/sh
# Builds "Checklist Calendar Sync.app", installs it, and schedules it every 15 minutes.
# Needs ~/.checklist-sync/key.json (Firebase service-account key) before uploads can work.
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
SUPPORT="$HOME/.checklist-sync"
APP="$HOME/Applications/Checklist Calendar Sync.app"
LABEL="org.checklist.calsync"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
NODE="$(command -v node)"

mkdir -p "$SUPPORT" "$APP/Contents/MacOS" "$HOME/Library/LaunchAgents"
chmod 700 "$SUPPORT"
cp "$HERE/upload.mjs" "$SUPPORT/upload.mjs"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleName</key><string>Checklist Calendar Sync</string>
  <key>CFBundleExecutable</key><string>CalSync</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
  <key>NSCalendarsUsageDescription</key><string>Copies your calendar events to your checklist site.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Copies your calendar events to your checklist site.</string>
</dict></plist>
EOF

swiftc -O "$HERE/CalSync.swift" -o "$APP/Contents/MacOS/CalSync"
codesign --force --sign - --identifier "$LABEL" "$APP"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/CalSync</string></array>
  <key>EnvironmentVariables</key><dict><key>CHECKLIST_NODE</key><string>$NODE</string></dict>
  <key>StartInterval</key><integer>900</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardErrorPath</key><string>$SUPPORT/sync.log</string>
  <key>StandardOutPath</key><string>$SUPPORT/sync.log</string>
</dict></plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed. Log: $SUPPORT/sync.log"
