#!/bin/bash
# Сборка лаунчера — PilotLauncher.app рядом с Pilot.app.
#
# Лаунчер открывают вместо Pilot.app (hop, Dock, Finder): он пересобирает
# Pilot, если исходники на диске разошлись с последней сборкой, и открывает
# его. Сам лаунчер от исходников Pilot не зависит — собрать один раз.
set -euo pipefail
cd "$(dirname "$0")"

APP="PilotLauncher.app"
REPO="$(pwd -P)"

echo "==> собираю $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/PilotLauncher" Launcher/main.swift

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                 <string>Pilot</string>
    <key>CFBundleDisplayName</key>          <string>Pilot</string>
    <key>CFBundleIdentifier</key>           <string>dev.local.pilot.launcher</string>
    <key>CFBundleExecutable</key>           <string>PilotLauncher</string>
    <key>CFBundleIconFile</key>             <string>Pilot</string>
    <key>CFBundleIconName</key>             <string>Pilot</string>
    <key>CFBundlePackageType</key>          <string>APPL</string>
    <key>CFBundleShortVersionString</key>   <string>1.0</string>
    <key>CFBundleVersion</key>              <string>1</string>
    <key>LSMinimumSystemVersion</key>       <string>14.0</string>
    <key>LSUIElement</key>                  <true/>
    <key>NSPrincipalClass</key>             <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>      <true/>
    <!-- Откуда собирать Pilot. -->
    <key>PilotRepo</key>                    <string>$REPO</string>
</dict>
</plist>
PLIST

# Иконка — та же, что у Pilot, если build.sh её уже собрал.
if [[ -f .build/icon/Assets.car ]]; then
    cp .build/icon/Assets.car .build/icon/Pilot.icns "$APP/Contents/Resources/"
fi

codesign --force --sign - "$APP" 2> /dev/null || echo "   (codesign пропущен)"
echo "Готово: $REPO/$APP"
