#!/bin/bash
# Сборка Pilot.app. Нужны Command Line Tools и Rust (для Rustlyn, которым
# разбирается C#) — Xcode-проект не требуется.
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="Pilot.app"

# Библиотека Rustlyn: ею Pilot разбирает C#. Собирается первой, потому что
# Swift компилируется против её заголовка и линкуется с ней самой.
#
# Здесь это обязательный шаг, а не необязательный: заголовка нет — модуль
# `CRustlyn` не соберётся, библиотеки нет — не слинкуется, и сказать об этом
# внятной строкой лучше, чем страницей ошибок компилятора. Заглушка в
# `RustlynAbsent.swift` — для тестов ядра, которые собирают подмножество
# исходников отдельным пакетом и без C-модуля; для приложения она не путь
# отхода.
./build-rust.sh

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

# Иконка — документ Icon Composer. actool из Xcode 26 собирает из него
# Assets.car (Liquid Glass со светлой, тёмной и тонированной версиями)
# и Pilot.icns для macOS 14–15. Иконка меняется редко, а run.sh собирает
# бандл на каждый запуск, поэтому результат лежит в .build и пересобирается,
# только когда что-то в Pilot.icon новее него. Пути абсолютные: actool
# отдаёт работу фоновому агенту, а тот считает относительные пути от своей папки.
ICON_SRC="$(pwd)/Resources/Pilot.icon"
ICON_OUT="$(pwd)/.build/icon"
if [[ ! -f "$ICON_OUT/Assets.car" || -n "$(find "$ICON_SRC" -newer "$ICON_OUT/Assets.car")" ]]; then
    rm -rf "$ICON_OUT"
    mkdir -p "$ICON_OUT"
    if ! xcrun --find actool > /dev/null 2>&1; then
        echo "   (actool не найден — нужен Xcode 26; бандл будет без иконки)"
    elif ! xcrun actool "$ICON_SRC" --compile "$ICON_OUT" --platform macosx \
            --minimum-deployment-target 14.0 --app-icon Pilot \
            --output-partial-info-plist "$ICON_OUT/partial.plist" \
            > "$ICON_OUT/actool.log" 2>&1 || [[ ! -f "$ICON_OUT/Assets.car" ]]; then
        echo "   (иконка не собралась — нужен Xcode 26, см. $ICON_OUT/actool.log)"
    fi
fi
if [[ -f "$ICON_OUT/Assets.car" ]]; then
    cp "$ICON_OUT/Assets.car" "$ICON_OUT/Pilot.icns" "$APP/Contents/Resources/"
fi

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
