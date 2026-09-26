#!/bin/bash
# Отладчик .NET для Pilot: netcoredbg от Samsung (MIT), говорит по DAP.
# Кладёт его в .build/netcoredbg; build.sh копирует оттуда в бандл.
# Скачивает один раз, закреплённую версию, со сверкой SHA256.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=3.2.0-1092
SHA256=f4fa33b3ff874910cc184b4bb3b9c56d0abdf5c6521cee0b144d7c6e4a6e59ea
OUT=.build/netcoredbg

if [[ "$(uname -m)" != "arm64" ]]; then
    echo "   (netcoredbg для macOS собран только под arm64 — отладка .NET недоступна)"
    exit 0
fi
if [[ -x "$OUT/netcoredbg" && "$(cat "$OUT/VERSION" 2>/dev/null)" == "$VERSION" ]]; then
    exit 0
fi

echo "==> скачиваю netcoredbg $VERSION"
rm -rf "$OUT"
mkdir -p "$OUT"
if ! curl -fsSL -o "$OUT/netcoredbg.zip" \
        "https://github.com/Samsung/netcoredbg/releases/download/$VERSION/netcoredbg-osx-arm64.zip"; then
    echo "   (netcoredbg не скачался — отладка .NET будет недоступна)"
    rm -rf "$OUT"
    exit 0
fi
echo "$SHA256  $OUT/netcoredbg.zip" | shasum -a 256 -c - > /dev/null
unzip -q -o "$OUT/netcoredbg.zip" -x "__MACOSX/*" -d "$OUT/unpacked"
mv "$OUT/unpacked/netcoredbg/"* "$OUT/"
rm -rf "$OUT/unpacked" "$OUT/netcoredbg.zip"
echo "$VERSION" > "$OUT/VERSION"
