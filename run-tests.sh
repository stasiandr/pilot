#!/bin/bash
# Тесты алгоритмического ядра: индекс файлов и типов, дерево файлов, fuzzy-поиск,
# .gitignore, лексер, распознавание ⇧⇧, git, события ФС, Unity: GUID, сцены,
# инспектор, метаданные сборок .NET.
# AppKit здесь не нужен, поэтому они гоняются и на macOS, и на Linux.
#
# Rustlyn здесь тоже нет: пакет собирается без CRustlyn, и `#if canImport`
# подставляет заглушку. Это не пробел, а то, что проверять и надо, — что
# Pilot без библиотеки собирается и отвечает сам. Что делает сама
# библиотека, проверяют её собственные тесты (`cargo test` в rustlyn).
set -euo pipefail
cd "$(dirname "$0")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/Sources/coretests"
cp Sources/Pilot/Model/{FuzzyMatch,FileIndex,FileTree,GitIgnore,GitInfo,AtomicCounter,PaletteItem,TypeIndex,DoubleShift,FilePreview,GitFiles,EditingRules,Tabs,OpenRequest,FileChanges}.swift "$TMP/Sources/coretests/"
cp Sources/Pilot/Highlight/{Language,Lexer,Outline,Occurrences}.swift "$TMP/Sources/coretests/"
cp Sources/Pilot/LSP/{JSONRPC,LSPTypes,PositionMapping,ServerConfig,LSPClient,LSPDaemon,UnixSocket,Completion}.swift "$TMP/Sources/coretests/"
cp Sources/Pilot/Git/{LineDiff,GitParsing,Git,MergeConflicts}.swift "$TMP/Sources/coretests/"
cp Sources/Pilot/Nav/{SymbolIndex,LocalNavigator}.swift "$TMP/Sources/coretests/"
cp Sources/Pilot/Decompile/{AssemblyMetadata,AssemblySignatures,AssemblySource,AssemblyIndex}.swift "$TMP/Sources/coretests/"
cp Sources/Pilot/GitLab/{GitLabRemote,GitLabModels,UnifiedDiff,MergeRequestSearch}.swift "$TMP/Sources/coretests/"
cp Sources/Pilot/Unity/{UnityProject,UnityAssetIndex,UnityYAML,UnityUsages,UnityCSharp,UnityProperties,UnityInspector,UnityHierarchy}.swift "$TMP/Sources/coretests/"
# Типы Rustlyn и заглушка на случай, когда библиотеки нет. Здесь её нет
# всегда: пакет собирается без CRustlyn, поэтому `#if canImport` выбирает
# заглушку, и проверяется ровно то, что Pilot делает своими силами.
cp Sources/Pilot/Rustlyn/{RustlynTypes,RustlynAbsent,RustlynNavigator}.swift "$TMP/Sources/coretests/"
cp CoreTests/CoreTests.swift "$TMP/Sources/coretests/main.swift"

cat > "$TMP/Package.swift" <<'MANIFEST'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "coretests",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "coretests", path: "Sources/coretests",
              swiftSettings: [.swiftLanguageMode(.v5)])]
)
MANIFEST

swift run -c release --package-path "$TMP" 2>&1 \
    | grep -v "^\[" | grep -v "^Building\|^Build of\|^Compiling\|^Linking\|Write "
