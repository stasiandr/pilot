#!/bin/bash
# Движок для APK, JAR и DEX: мост к jadx (src/pilot/JadxEngine.java) и сам jadx.
# Кладёт engine.jar и jadx.jar в .build/jadx. Нужен JDK: brew install openjdk.
# Пересобирает мост, только когда исходник новее jar.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=1.5.6
SHA256=545ea2be9c242511bc145755cf4bda2485ade42966e096f8b4d3da2a230e8974
OUT=.build/jadx
JDK="${JAVA_HOME:-/opt/homebrew/opt/openjdk}"

if [[ ! -x "$JDK/bin/javac" ]]; then
    echo "   (JDK не найден в $JDK — APK и JAR открываться не будут)"
    exit 0
fi
mkdir -p "$OUT"

if [[ ! -f "$OUT/jadx.jar" ]]; then
    echo "==> скачиваю jadx $VERSION"
    curl -fsSL -o "$OUT/jadx.zip" "https://github.com/skylot/jadx/releases/download/v$VERSION/jadx-$VERSION.zip"
    echo "$SHA256  $OUT/jadx.zip" | shasum -a 256 -c - > /dev/null
    unzip -q -o -j "$OUT/jadx.zip" "lib/jadx-$VERSION-all.jar" -d "$OUT"
    mv "$OUT/jadx-$VERSION-all.jar" "$OUT/jadx.jar"
    rm "$OUT/jadx.zip"
fi

if [[ ! -f "$OUT/engine.jar" || -n "$(find Jadx/src -newer "$OUT/engine.jar" -name '*.java')" ]]; then
    echo "==> собираю мост к jadx"
    rm -rf "$OUT/classes"
    "$JDK/bin/javac" --release 21 -nowarn -cp "$OUT/jadx.jar" -d "$OUT/classes" $(find Jadx/src -name '*.java')
    "$JDK/bin/jar" --create --file "$OUT/engine.jar" -C "$OUT/classes" .
    rm -rf "$OUT/classes"
fi
