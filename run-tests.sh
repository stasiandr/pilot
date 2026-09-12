#!/bin/bash
# Тесты алгоритмического ядра: индекс, fuzzy-поиск, .gitignore, лексер.
# AppKit здесь не нужен, поэтому они гоняются и на macOS, и на Linux.
set -euo pipefail
cd "$(dirname "$0")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/Sources/coretests"
cp Sources/Flint/Model/{FuzzyMatch,FileIndex,GitIgnore,AtomicCounter,PaletteItem}.swift "$TMP/Sources/coretests/"
cp Sources/Flint/Highlight/{Language,Lexer,Outline,Occurrences}.swift "$TMP/Sources/coretests/"
cp Sources/Flint/LSP/{JSONRPC,LSPTypes,PositionMapping,ServerConfig,LSPClient}.swift "$TMP/Sources/coretests/"
cp CoreTests/CoreTests.swift "$TMP/Sources/coretests/main.swift"

cat > "$TMP/Package.swift" <<'MANIFEST'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "coretests",
    targets: [.executableTarget(name: "coretests", path: "Sources/coretests",
              swiftSettings: [.swiftLanguageMode(.v5)])]
)
MANIFEST

swift run -c release --package-path "$TMP" 2>&1 \
    | grep -v "^\[" | grep -v "^Building\|^Build of\|^Compiling\|^Linking\|Write "
