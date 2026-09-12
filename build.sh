#!/bin/bash
# Сборка Pilot.app. Нужны только Command Line Tools — Xcode-проект не требуется.
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="Pilot.app"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/Pilot"
if [[ ! -f "$BIN" ]]; then
    echo "Бинарник не найден: $BIN" >&2
    exit 1
fi

echo "==> собираю бандл $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Pilot"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc подпись: без неё macOS не даст приложению доступ к файлам
# и будет ругаться при каждом запуске.
codesign --force --deep --sign - "$APP" 2>/dev/null || \
    echo "   (codesign пропущен — приложение всё равно запустится)"

echo
echo "Готово: $(pwd)/$APP"
echo "Запуск:   open $APP"
echo "Замер:    time ./$APP/Contents/MacOS/Pilot"
echo
echo "Чтобы положить в /Applications:"
echo "   cp -R $APP /Applications/"
