#!/bin/bash
# Сборка и запуск Pilot.
#
#   ./run.sh                     последний открытый проект
#   ./run.sh ~/code/project      открыть папку
#   ./run.sh path/to/File.cs     открыть файл; корень — ближайший git-репозиторий
#
# По умолчанию собирается debug — так быстрее. Замерять скорость: CONFIG=release ./run.sh
# Уже запущенный Pilot закрывается: иначе macOS активирует старый экземпляр
# и не передаст ему путь.
set -euo pipefail

TARGET=""
if [[ $# -gt 0 ]]; then
    if [[ ! -e "$1" ]]; then
        echo "Нет такого файла или папки: $1" >&2
        exit 1
    fi
    # Абсолютный путь считаем до cd: относительный — от текущей папки.
    if [[ -d "$1" ]]; then
        TARGET="$(cd "$1" && pwd -P)"
    else
        TARGET="$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")"
    fi
fi

cd "$(dirname "$0")"
CONFIG="${CONFIG:-debug}"
LOG=".build/pilot.log"
mkdir -p .build

echo "==> сборка ($CONFIG)"
if ! ./build.sh "$CONFIG" > .build/run-build.log 2>&1; then
    grep -E "error:|Бинарник" .build/run-build.log || cat .build/run-build.log
    exit 1
fi

if pgrep -x Pilot > /dev/null; then
    echo "==> закрываю запущенный Pilot"
    pkill -x Pilot || true
    for _ in {1..30}; do
        pgrep -x Pilot > /dev/null || break
        sleep 0.1
    done
fi

echo "==> запуск${TARGET:+: $TARGET}"
: > "$LOG"
open -n Pilot.app --stdout "$LOG" --stderr "$LOG" ${TARGET:+--args "$TARGET"}
echo "    лог: tail -f $(pwd)/$LOG"
