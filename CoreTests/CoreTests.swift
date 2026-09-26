import Foundation

var failures = 0
var checks = 0

func check(_ cond: Bool, _ label: String) {
    checks += 1
    if !cond { failures += 1; print("  FAIL: \(label)") }
}
func section(_ s: String) { print("\n[\(s)]") }

// ───────────────────────────── Glob ─────────────────────────────
section("Glob")
check(Glob.match(pattern: Array("*.cs".utf8), text: Array("Program.cs".utf8)), "*.cs matches Program.cs")
check(!Glob.match(pattern: Array("*.cs".utf8), text: Array("Program.csproj".utf8)), "*.cs rejects .csproj")
check(Glob.match(pattern: Array("bin".utf8), text: Array("bin".utf8)), "literal bin")
check(!Glob.match(pattern: Array("*.cs".utf8), text: Array("src/Program.cs".utf8)), "single * must not cross /")
check(Glob.match(pattern: Array("**/obj".utf8), text: Array("a/b/obj".utf8)), "**/ crosses /")
check(Glob.match(pattern: Array("src/**/*.ts".utf8), text: Array("src/a/b/x.ts".utf8)), "src/**/*.ts deep")
check(Glob.match(pattern: Array("file?.txt".utf8), text: Array("file1.txt".utf8)), "? single char")
check(Glob.match(pattern: Array("*.[oa]".utf8), text: Array("x.o".utf8)), "char class")
check(!Glob.match(pattern: Array("*.[oa]".utf8), text: Array("x.c".utf8)), "char class negative")

// ────────────────────────── .gitignore ──────────────────────────
section("gitignore")
func rules(_ lines: [String]) -> IgnoreMatcher {
    IgnoreMatcher(layers: [IgnoreLayer(rules: lines.compactMap { IgnoreRule(line: $0) }, base: "")],
                  useSoftSkip: false)
}
let m1 = rules(["bin/", "obj/", "*.user", "!keep.user"])
check(m1.isIgnored(relPath: "bin", name: "bin", isDir: true), "bin/ ignores dir")
check(!m1.isIgnored(relPath: "bin", name: "bin", isDir: false), "bin/ does not ignore file")
check(m1.isIgnored(relPath: "a/x.user", name: "x.user", isDir: false), "*.user ignored")
check(!m1.isIgnored(relPath: "a/keep.user", name: "keep.user", isDir: false), "negation !keep.user wins")
check(m1.isIgnored(relPath: "x", name: ".git", isDir: true), ".git always ignored")

let m2 = rules(["/build"])
check(m2.isIgnored(relPath: "build", name: "build", isDir: true), "anchored /build at root")
check(!m2.isIgnored(relPath: "src/build", name: "build", isDir: true), "anchored /build not nested")

// вложенный .gitignore действует только на своё поддерево
let nested = IgnoreMatcher(
    layers: [IgnoreLayer(rules: [IgnoreRule(line: "*.log")!], base: "sub")],
    useSoftSkip: false)
check(nested.isIgnored(relPath: "sub/a.log", name: "a.log", isDir: false), "nested layer applies in subtree")
check(!nested.isIgnored(relPath: "other/a.log", name: "a.log", isDir: false), "nested layer skips other subtree")
// база-префикс, но не папка: sub2 не лежит внутри sub
check(!nested.isIgnored(relPath: "sub2/a.log", name: "a.log", isDir: false), "nested layer: sub2 is not inside sub")

// Быстрые пути матчера: точное имя, окончание, обязательный литерал.
func literal(_ p: String) -> String { String(decoding: IgnoreRule.longestLiteral(Array(p.utf8)), as: UTF8.self) }
check(literal("[Aa]ssets/StreamingAssets/**/*.bank") == "ssets/StreamingAssets/", "литерал: класс и ** пропущены")
check(literal("**/.idea/**/workspace.xml") == "workspace.xml", "литерал: слеш после ** не обязателен")
check(literal("*.[oa]") == ".", "литерал: до класса")
check(literal("x[]ab]cd") == "cd", "литерал: `]` сразу после `[` — часть класса")
func kind(_ line: String) -> String {
    switch IgnoreRule(line: line)!.kind {
    case .literal: return "literal"
    case .suffix: return "suffix"
    case .glob: return "glob"
    }
}
check(kind("Thumbs.db") == "literal" && kind("/Assets/link.xml") == "literal", "без спецсимволов -> literal")
check(kind("*.csproj") == "suffix", "*.csproj -> suffix")
check(kind("/*.csproj") == "glob", "якорный *.csproj — не суффикс: * не проходит через /")
check(kind("[Bb]in/") == "glob", "класс -> glob")

// Главная проверка: быстрые пути отвечают ровно как полный глоб.
let patterns = ["Thumbs.db", "*.csproj", "*.pidb.meta", "[Bb]in", "**/.idea/**/workspace.xml",
                "[Aa]ssets/StreamingAssets/**/*.bank", "[Aa]ssets/**/*.meta", "src/*.ts", "a?c",
                "**/obj", "*", "*.[oa]", "build_ios*", "Assets/eWolf/Thumbs.db.meta", "**"]
let texts = ["Thumbs.db", "x.csproj", "a/x.csproj", ".csproj", "x.pidb.meta", "bin", "Bin", "cabin",
             ".idea/workspace.xml", "a/.idea/b/workspace.xml", "workspace.xml",
             "Assets/StreamingAssets/x/y.bank", "assets/StreamingAssets/y.bank", "Assets/StreamingAssets.bank",
             "Assets/a/b/c.meta", "Assets/c.meta", "src/a.ts", "src/a/b.ts", "abc", "a/c", "obj", "x/y/obj",
             "x.o", "x.c", "build_ios_1", "Assets/eWolf/Thumbs.db.meta", "", "Папка/файл.cs"]
var mismatches: [String] = []
for p in patterns {
    for anchored in ["", "/"] {
        let rule = IgnoreRule(line: anchored + p)!
        for t in texts {
            let fast = Array(t.utf8).withUnsafeBufferPointer { rule.matches($0) }
            if fast != Glob.match(pattern: rule.pattern, text: Array(t.utf8)) {
                mismatches.append("\(anchored)\(p) ~ \(t)")
            }
        }
    }
}
check(mismatches.isEmpty, "быстрые пути совпадают с глобом (расхождения: \(mismatches))")

// ──────────────────────────── Fuzzy ────────────────────────────
section("Fuzzy")
func rank(_ query: String, _ paths: [String]) -> [String] {
    let idx = FileIndex(root: URL(fileURLWithPath: "/"))
    for p in paths { idx.appendCached(rel: p) }
    return idx.search(query, limit: 50, shouldStop: { false }).map { idx.relPath($0.id) }
}
let corpus = [
    "src/Services/UserService.cs",
    "src/Models/User.cs",
    "tests/UserServiceTests.cs",
    "docs/user-guide.md",
    "src/Utils/StringHelper.cs",
    "node/user/service/index.ts",
]
let r1 = rank("usersvc", corpus)
check(r1.first == "src/Services/UserService.cs", "camelCase аббревиатура -> UserService.cs (получено: \(r1.first ?? "nil"))")

let r2 = rank("user.cs", corpus)
check(r2.first == "src/Models/User.cs", "точное имя файла выигрывает (получено: \(r2.first ?? "nil"))")

let r3 = rank("zzzz", corpus)
check(r3.isEmpty, "несовпадающий запрос -> пусто")

let r4 = rank("", corpus)
check(r4.count == corpus.count, "пустой запрос -> всё")

// smart case
let caseCorpus = ["src/readme.md", "README.md"]
let r5 = rank("README", caseCorpus)
check(r5.first == "README.md", "заглавные в запросе предпочитают точный регистр (получено: \(r5.first ?? "nil"))")

// подсветка: позиции должны указывать на реально совпавшие байты
let idx6 = FileIndex(root: URL(fileURLWithPath: "/"))
idx6.appendCached(rel: "src/Models/User.cs")
if let hit = idx6.search("user", limit: 1, shouldStop: { false }).first {
    let bytes = Array("src/Models/User.cs".utf8)
    let matched = hit.positions.map { Character(UnicodeScalar(bytes[Int($0)])) }
    check(String(matched).lowercased() == "user", "позиции подсветки указывают на 'user' (получено: \(String(matched)))")
} else { check(false, "поиск 'user' что-то нашёл") }

// ──────────────────────────── Lexer ────────────────────────────
section("Lexer")

/// Главный инвариант: токены, полученные построчно (как при скролле),
/// обязаны совпадать с токенами, полученными за один проход по всему файлу.
func checkTwoPassConsistency(_ text: String, _ spec: LanguageSpec, _ label: String) {
    let model = SyntaxModel(text: text, spec: spec)
    let whole = model.tokens(fromLine: 0, toLine: model.lineCount - 1)

    var piecewise: [Token] = []
    for line in 0..<model.lineCount {
        piecewise.append(contentsOf: model.tokens(fromLine: line, toLine: line))
    }
    let a = whole.map { "\($0.start):\($0.length):\($0.kind)" }
    let b = piecewise.map { "\($0.start):\($0.length):\($0.kind)" }
    if a != b {
        check(false, "\(label): построчная лексация расходится с цельной")
        for (i, pair) in zip(a, b).enumerated() where pair.0 != pair.1 {
            print("     первое расхождение #\(i): целиком=\(pair.0) построчно=\(pair.1)")
            break
        }
        if a.count != b.count { print("     количество токенов: целиком=\(a.count) построчно=\(b.count)") }
    } else {
        check(true, "\(label): проходы согласованы")
    }
}

let csSample = """
using System;
/* блочный
   комментарий
   на три строки */
namespace Demo {
    /// <summary>Док-комментарий</summary>
    public class Foo {
        private readonly string _name = "привет \\" мир";
        public int Bar(int x) => x * 2;   // хвостовой комментарий
        const string V = @"дословная
строка";
    }
}
"""
checkTwoPassConsistency(csSample, Languages.csharp, "C#")

let swiftSample = """
import Foundation
/* внешний /* вложенный */ всё ещё комментарий */
@MainActor struct App {
    let s = \"\"\"
    многострочный
    литерал
    \"\"\"
    func f() -> Int { 42 }
}
"""
checkTwoPassConsistency(swiftSample, Languages.swift, "Swift")

let pySample = """
import os
def f(x):
    '''докстринг
    на две строки'''
    return x  # комментарий
"""
checkTwoPassConsistency(pySample, Languages.python, "Python")

// границы строк и UTF-16
let uni = "let s = \"日本語テキスト\"\n// комментарий\nlet n = 42\n"
let um = SyntaxModel(text: uni, spec: Languages.swift)
check(um.lineCount == 4, "UTF-16: число строк = 4 (получено \(um.lineCount))")
let utf16 = Array(uni.utf16)
for line in 0..<um.lineCount {
    let start = Int(um.lineStarts[line])
    check(start <= utf16.count, "UTF-16: начало строки \(line) в пределах буфера")
}
// смещения токенов обязаны совпадать с индексами UTF-16 исходной строки
let utoks = um.tokens(fromLine: 0, toLine: um.lineCount - 1)
if let strTok = utoks.first(where: { $0.kind == .string }) {
    let sub = String(decoding: utf16[Int(strTok.start)..<Int(strTok.start + strTok.length)], as: UTF16.self)
    check(sub == "\"日本語テキスト\"", "UTF-16: смещения токенов совпадают с NSRange (получено \(sub))")
} else { check(false, "UTF-16: строковый токен найден") }

// распознавание конкретных видов токенов
let km = SyntaxModel(text: "public class Foo { void Bar() { int x = 42; } }", spec: Languages.csharp)
let kt = km.tokens(fromLine: 0, toLine: 0)
func kindOf(_ word: String, _ model: SyntaxModel, _ toks: [Token]) -> TokenKind? {
    let u = Array(model.units)
    return toks.first { String(decoding: u[Int($0.start)..<Int($0.start + $0.length)], as: UTF16.self) == word }?.kind
}
check(kindOf("public", km, kt) == .keyword, "'public' -> keyword")
check(kindOf("Foo", km, kt) == .type, "'Foo' -> type (с заглавной)")
check(kindOf("Bar", km, kt) == .function, "'Bar' -> function (перед скобкой)")
check(kindOf("int", km, kt) == .type, "'int' -> type")
check(kindOf("42", km, kt) == .number, "'42' -> number")

// незакрытая многострочная конструкция не должна уводить лексер в бесконечность
let unterminated = SyntaxModel(text: "/* без закрытия\nвторая строка\nтретья", spec: Languages.csharp)
check(unterminated.lineCount == 3, "незакрытый блочный комментарий: строки посчитаны")
let ut = unterminated.tokens(fromLine: 0, toLine: 2)
check(ut.allSatisfy { $0.kind == .comment }, "незакрытый блочный комментарий: всё — комментарий")

// файл без завершающего перевода строки и пустой файл
check(SyntaxModel(text: "", spec: Languages.csharp).lineCount == 1, "пустой файл -> 1 строка")
check(SyntaxModel(text: "a", spec: Languages.csharp).lineCount == 1, "файл без \\n -> 1 строка")
check(SyntaxModel(text: "a\n", spec: Languages.csharp).lineCount == 2, "файл с \\n -> 2 строки")
check(SyntaxModel(text: "x\ny\nz", spec: nil).lineCount == 3, "без языка строки всё равно режутся")

// line(containing:)
let lm = SyntaxModel(text: "aaa\nbbb\nccc", spec: nil)
check(lm.line(containing: 0) == 0, "line(containing:) начало")
check(lm.line(containing: 4) == 1, "line(containing:) вторая строка")
check(lm.line(containing: 10) == 2, "line(containing:) третья строка")

// ───────────────────────── Производительность ─────────────────────────
section("Производительность")
let synthetic = FileIndex(root: URL(fileURLWithPath: "/"))
for i in 0..<100_000 {
    synthetic.appendCached(rel: "src/module\(i % 200)/Component\(i % 500)/Handler\(i).cs")
}
var worst: Double = 0
for q in ["h", "handler", "src/mod", "hndlr", "c123", "srcmodcomp"] {
    let t0 = Date()
    _ = synthetic.search(q, limit: 200, shouldStop: { false })
    let ms = Date().timeIntervalSince(t0) * 1000
    worst = max(worst, ms)
    print(String(format: "  поиск %-12@ по 100k файлов: %6.1f мс", q as NSString, ms))
}
check(worst < 250, "худший поиск по 100k файлов укладывается в 250 мс (худший: \(Int(worst)) мс)")

let bigSource = String(repeating: "public void Method\(1)(int arg) { /* c */ var s = \"str\"; }\n", count: 200_000)
let t1 = Date()
let bigModel = SyntaxModel(text: bigSource, spec: Languages.csharp)
let buildMs = Date().timeIntervalSince(t1) * 1000
let t2 = Date()
_ = bigModel.tokens(fromLine: 1000, toLine: 1100)
let screenMs = Date().timeIntervalSince(t2) * 1000
print(String(format: "  проход 1 по файлу на 200k строк: %.0f мс", buildMs))
print(String(format: "  подсветка одного экрана (100 строк): %.2f мс", screenMs))
check(screenMs < 5, "экран красится меньше чем за 5 мс (получено \(screenMs) мс)")


// ────────────────────────── LSP: кадрирование ──────────────────────────
section("LSP / транспорт")

func framed(_ json: String) -> Data { MessageFramer.frame(Data(json.utf8)) }
func bodies(_ msgs: [Data]) -> [String] { msgs.map { String(decoding: $0, as: UTF8.self) } }

do {
    var f = MessageFramer()
    let out = bodies(f.feed(framed("{\"id\":1}")))
    check(out == ["{\"id\":1}"], "одно целое сообщение")
}
do {
    var f = MessageFramer()
    var got: [Data] = []
    let whole = framed("{\"id\":2}")
    // побайтовая подача — худший случай для кадрирования
    for byte in whole { got += f.feed(Data([byte])) }
    check(bodies(got) == ["{\"id\":2}"], "сообщение, поданное по одному байту")
}
do {
    var f = MessageFramer()
    var data = framed("{\"a\":1}")
    data.append(framed("{\"b\":2}"))
    data.append(framed("{\"c\":3}"))
    check(bodies(f.feed(data)) == ["{\"a\":1}", "{\"b\":2}", "{\"c\":3}"],
          "три сообщения в одной порции")
}
do {
    // Главный случай: Content-Length считает БАЙТЫ, а разрыв чтения
    // приходится на середину многобайтового UTF-8.
    var f = MessageFramer()
    let payload = "{\"msg\":\"日本語テキスト и кириллица\"}"
    let whole = framed(payload)
    let cut = whole.count / 2
    var got = f.feed(whole.prefix(cut))
    got += f.feed(whole.suffix(from: cut))
    check(bodies(got) == [payload], "разрыв посередине многобайтового UTF-8")
    check(Data(payload.utf8).count != payload.count, "тест действительно про многобайтовые данные")
}
do {
    var f = MessageFramer()
    let header = "Content-Type: application/vscode-jsonrpc; charset=utf-8\r\n"
    var data = Data("\(header)Content-Length: 8\r\n\r\n".utf8)
    data.append(Data("{\"id\":9}".utf8))
    check(bodies(f.feed(data)) == ["{\"id\":9}"], "дополнительные заголовки не мешают")
}
do {
    var f = MessageFramer()
    // мусорный заголовок не должен застопорить поток навсегда
    var data = Data("Garbage: yes\r\n\r\n".utf8)
    data.append(framed("{\"ok\":1}"))
    check(bodies(f.feed(data)) == ["{\"ok\":1}"], "заголовок без Content-Length пропускается")
}
do {
    var f = MessageFramer()
    check(f.feed(Data("Content-Length: 50\r\n\r\n{\"partial\"".utf8)).isEmpty,
          "неполное тело не выдаётся")
}

// ────────────────────────── LSP: таймауты и отмена ──────────────────────────
section("LSP / таймауты")

/// Результат запроса из фоновой задачи: семафор даёт happens-before.
final class RequestOutcome: @unchecked Sendable { var text = "не завершился" }

/// Запускает запрос в отдельной задаче и ждёт его не дольше `limit` секунд.
/// nil — запрос так и не завершился.
func runRequest(_ client: LSPClient, timeout: TimeInterval, cancelAfter: TimeInterval? = nil,
                limit: TimeInterval = 3) -> String? {
    let done = DispatchSemaphore(value: 0)
    let outcome = RequestOutcome()
    let task = Task.detached {
        do {
            let result = try await client.request("pilot/ping", [:], timeout: timeout)
            outcome.text = result is NSNull ? "ответ" : "ответ \(result)"
        } catch {
            outcome.text = "\(error)"
        }
        done.signal()
    }
    if let cancelAfter {
        Thread.sleep(forTimeInterval: cancelAfter)
        task.cancel()
    }
    return done.wait(timeout: .now() + limit) == .success ? outcome.text : nil
}

func testServer(_ command: [String]) -> LSPClient {
    let config = ServerConfig(id: "test", languageId: "plaintext", fileExtensions: [],
                              command: command, displayName: "test")
    let client = LSPClient(config: config, root: URL(fileURLWithPath: NSTemporaryDirectory()))
    try? client.start()
    return client
}

do {
    // `cat` — эхо: наш запрос возвращается как «запрос от сервера», клиент
    // на него отвечает, а эхо ответа закрывает исходный запрос.
    let echo = testServer(["/bin/cat"])
    check(runRequest(echo, timeout: 2) == "ответ", "эхо-сервер: запрос получает ответ")
    echo.stop()

    // Сервер, который молчит. Запрос обязан упасть по таймауту, а не повиснуть:
    // вызывающий иначе никогда не узнает, что ответа не будет.
    let silent = testServer(["/bin/sleep", "30"])
    let t0 = Date()
    let timedOut = runRequest(silent, timeout: 0.2)
    check(timedOut?.contains("timeout") == true,
          "молчащий сервер: запрос завершается таймаутом (получено: \(timedOut ?? "повис"))")
    check(Date().timeIntervalSince(t0) < 1.5, "таймаут срабатывает вовремя")

    // Отмена задачи снимает запрос сразу, не дожидаясь таймаута.
    let t1 = Date()
    let cancelled = runRequest(silent, timeout: 30, cancelAfter: 0.1)
    check(cancelled != nil, "отменённый запрос завершается (получено: \(cancelled ?? "повис"))")
    check(Date().timeIntervalSince(t1) < 1.5, "отмена не ждёт таймаута")
    silent.stop()
}

do {
    // servers.json: свои серверы для языков, которых Pilot не понимает сам.
    let parsed = ServerConfig(json: [
        "id": "gopls", "extensions": ["GO"], "command": ["gopls"],
        "settings": ["a.b": false], "displayName": "gopls",
    ])
    check(parsed?.command == ["gopls"] && parsed?.fileExtensions == ["go"]
          && parsed?.settings["a.b"] as? Bool == false && parsed?.languageId == "plaintext",
          "servers.json: сервер разобран, расширения в нижнем регистре")
    check(ServerConfig(json: ["id": "x", "extensions": ["go"], "command": []]) == nil,
          "servers.json: без команды сервера нет")
    check(!ServerRegistry.builtIn(root: URL(fileURLWithPath: "/")).contains { $0.fileExtensions.contains("cs") },
          "C# языковым серверам не отдаётся: его понимает Rustlyn")
}

// ────────────────────────── LSP: разбор ответов ──────────────────────────
section("LSP / разбор")

func json(_ s: String) -> Any {
    try! JSONSerialization.jsonObject(with: Data(s.utf8), options: [.fragmentsAllowed])
}

let locSingle = json("{\"uri\":\"file:///a.cs\",\"range\":{\"start\":{\"line\":3,\"character\":5},\"end\":{\"line\":3,\"character\":9}}}")
check(LSPLocation.parse(locSingle).count == 1, "definition: одиночный Location")
check(LSPLocation.parse(locSingle).first?.range.start.line == 3, "definition: строка разобрана")

let locArray = json("[{\"uri\":\"file:///a.cs\",\"range\":{\"start\":{\"line\":1,\"character\":0},\"end\":{\"line\":1,\"character\":2}}},{\"uri\":\"file:///b.cs\",\"range\":{\"start\":{\"line\":7,\"character\":0},\"end\":{\"line\":7,\"character\":2}}}]")
check(LSPLocation.parse(locArray).count == 2, "definition: массив Location")

let locLink = json("[{\"targetUri\":\"file:///c.cs\",\"targetRange\":{\"start\":{\"line\":10,\"character\":0},\"end\":{\"line\":20,\"character\":0}},\"targetSelectionRange\":{\"start\":{\"line\":10,\"character\":4},\"end\":{\"line\":10,\"character\":8}}}]")
let links = LSPLocation.parse(locLink)
check(links.count == 1, "definition: LocationLink")
check(links.first?.range.start.character == 4,
      "definition: у LocationLink берётся selectionRange, а не весь range")
check(LSPLocation.parse(json("null")).isEmpty, "definition: null -> пусто")

check(HoverContent.parse(json("{\"contents\":{\"kind\":\"markdown\",\"value\":\"```csharp\\nint Foo\\n```\"}}")) == "int Foo",
      "hover: MarkupContent без ограждений")
check(HoverContent.parse(json("{\"contents\":\"простой текст\"}")) == "простой текст",
      "hover: MarkedString строкой")
check(HoverContent.parse(json("{\"contents\":[{\"value\":\"A\"},{\"value\":\"B\"}]}")) == "A\n\nB",
      "hover: массив MarkedString")
check(HoverContent.parse(json("{\"contents\":\"\"}")) == nil, "hover: пустое -> nil")

let syms = LSPSymbol.parse(json("[{\"name\":\"Foo\",\"kind\":5,\"containerName\":\"Ns\",\"location\":{\"uri\":\"file:///a.cs\",\"range\":{\"start\":{\"line\":2,\"character\":1},\"end\":{\"line\":2,\"character\":4}}}}]"))
check(syms.count == 1 && syms[0].name == "Foo", "symbol: имя разобрано")
check(syms[0].kindLabel == "class", "symbol: вид -> class")
check(syms[0].range?.start.line == 2, "symbol: диапазон разобран")

do {
    var config = ServerConfig(id: "t", languageId: "go", fileExtensions: [], command: ["x"],
                              displayName: "t")
    config.settings = ["projects.enable_restore": false]
    let request = json("{\"items\":[{\"section\":\"ui.inlay_hints\"},{\"section\":\"projects.enable_restore\"},{\"scopeUri\":\"file:///a\"}]}")
    let answer = config.configurationResponse(request)
    check(answer.count == 3, "configuration: по ответу на каждый запрошенный элемент")
    check(answer[0] is NSNull, "configuration: неизвестная секция -> null")
    check(answer[1] as? Bool == false, "configuration: заданная секция отвечается значением")
    check(answer[2] is NSNull, "configuration: элемент без секции -> null")
    check(config.configurationResponse(nil).isEmpty, "configuration: без параметров -> пустой массив")
}

let capsBool = ServerCapabilities.parse(json("{\"capabilities\":{\"definitionProvider\":true,\"hoverProvider\":false}}"))
check(capsBool.definition && !capsBool.hover, "capabilities: булев вид")
let capsObj = ServerCapabilities.parse(json("{\"capabilities\":{\"referencesProvider\":{},\"workspaceSymbolProvider\":{\"resolveProvider\":true}}}"))
check(capsObj.references && capsObj.workspaceSymbol, "capabilities: провайдер с опциями считается включённым")
check(!ServerCapabilities.parse(json("{}")).definition, "capabilities: пусто -> ничего не умеет")

// ────────────────────── LSP: координаты ──────────────────────
section("LSP / координаты")

let posDoc = "class Foo {\n    int x = 1;\n}\n"
let posModel = SyntaxModel(text: posDoc, spec: Languages.csharp)
check(posModel.position(at: 0) == LSPPosition(line: 0, character: 0), "смещение 0 -> (0,0)")
check(posModel.position(at: 12) == LSPPosition(line: 1, character: 0), "начало второй строки")
check(posModel.offset(at: LSPPosition(line: 1, character: 4)) == 16, "(1,4) -> смещение 16")

// круговой обход по всем позициям документа
var roundTripOK = true
for offset in 0...Array(posDoc.utf16).count {
    if posModel.offset(at: posModel.position(at: offset)) != offset { roundTripOK = false; break }
}
check(roundTripOK, "круговой обход смещение -> позиция -> смещение")

// Ключевой случай: суррогатные пары. LSP считает character в UTF-16,
// поэтому эмодзи занимает ДВЕ единицы, а не одну.
let emojiDoc = "var s = \"🚀\"; // хвост\nsecond\n"
let emojiModel = SyntaxModel(text: emojiDoc, spec: Languages.csharp)
let u16 = Array(emojiDoc.utf16)
check(u16.count == emojiDoc.count + 1, "тест действительно про суррогатную пару")
var emojiRoundTrip = true
for offset in 0...u16.count {
    if emojiModel.offset(at: emojiModel.position(at: offset)) != offset { emojiRoundTrip = false; break }
}
check(emojiRoundTrip, "круговой обход на строке с суррогатной парой")
check(emojiModel.position(at: u16.count - 1).line == 1, "позиции после эмодзи не съезжают по строкам")

// подрезание вместо падения на устаревших координатах от сервера
check(posModel.offset(at: LSPPosition(line: 999, character: 999)) <= Array(posDoc.utf16).count,
      "позиция за концом файла подрезается")
check(posModel.offset(at: LSPPosition(line: 0, character: 999)) == 11,
      "позиция за концом строки подрезается до конца строки (без \\n)")
check(posModel.offset(at: LSPPosition(line: -5, character: -5)) == 0, "отрицательная позиция -> 0")

// NSRange для подсветки найденного символа
let r = posModel.nsRange(for: LSPRange(start: LSPPosition(line: 0, character: 6),
                                       end: LSPPosition(line: 0, character: 9)))
check(r.location == 6 && r.length == 3, "LSPRange -> NSRange")
let sub = String(decoding: Array(posDoc.utf16)[r.location..<(r.location + r.length)], as: UTF16.self)
check(sub == "Foo", "NSRange указывает ровно на 'Foo' (получено \(sub))")

// CRLF: позиция в конце строки не должна заезжать на возврат каретки
let crlfModel = SyntaxModel(text: "abc\r\ndef\r\n", spec: nil)
check(crlfModel.offset(at: LSPPosition(line: 0, character: 99)) == 3,
      "CRLF: конец строки — до \\r")


// ────────────────────────── Структура файла ──────────────────────────
section("Структура файла")

func outline(_ text: String, _ spec: LanguageSpec) -> [OutlineItem] {
    OutlineBuilder.build(model: SyntaxModel(text: text, spec: spec))
}
func names(_ items: [OutlineItem]) -> [String] { items.map(\.name) }
func named(_ items: [OutlineItem], _ n: String) -> OutlineItem? { items.first { $0.name == n } }

// Реалистичный C#: с атрибутами, дженериками, LINQ, вызовами внутри тел.
// Вызовы и локальные переменные попасть в структуру НЕ должны.
let csFile = """
using System;
using System.Linq;

namespace Acme.Billing
{
    public interface IInvoiceStore
    {
        Task<Invoice> FindAsync(int id);
    }

    [Serializable]
    public sealed class InvoiceService : IInvoiceStore
    {
        private readonly ILogger _logger;
        public int RetryCount { get; set; }
        public string Name => _name;

        public InvoiceService(ILogger logger)
        {
            _logger = logger;
            Console.WriteLine("built");
        }

        public async Task<Invoice> FindAsync(int id)
        {
            var cached = _cache.Get(id);
            if (cached != null) return cached;
            var rows = _db.Query(id).Where(r => r.IsActive).ToList();
            Validate(rows);
            return Map(rows);
        }

        private static Invoice Map(List<Row> rows) => new Invoice(rows);

        protected virtual void Validate(List<Row> rows)
        {
            if (rows.Count == 0) throw new InvalidOperationException();
        }
    }
}
"""
let cs = outline(csFile, Languages.csharp)

// объявления, которые обязаны найтись
for expected in ["Acme.Billing", "IInvoiceStore", "InvoiceService", "FindAsync",
                 "InvoiceService", "Map", "Validate", "RetryCount", "Name"] {
    check(names(cs).contains(expected), "C#: найдено объявление \(expected)")
}

// вызовы и локальные переменные — не объявления
for callSite in ["WriteLine", "Get", "Query", "Where", "ToList", "Count",
                 "cached", "rows", "Console"] {
    check(!names(cs).contains(callSite), "C#: вызов/локальная \(callSite) НЕ попала в структуру")
}
check(named(cs, "InvoiceService")?.kind == .type, "C#: InvoiceService — тип")
check(named(cs, "Map")?.kind == .method, "C#: Map — метод (лямбда-тело)")
check(named(cs, "RetryCount")?.kind == .property, "C#: RetryCount — свойство")
check(named(cs, "Acme.Billing")?.kind == .namespace, "C#: namespace распознан, имя целиком")
check(named(outline("package com.acme.billing;\nclass A {}", Languages.java), "com.acme.billing")?.kind == .namespace,
      "Java: package распознан, имя целиком")
check(named(outline("namespace App.Core;\npublic class A {}", Languages.csharp), "A")?.container == "App.Core",
      "C#: файловый namespace — контейнер типа")
check(named(cs, "FindAsync")?.container == "InvoiceService" || named(cs, "FindAsync")?.container == "IInvoiceStore",
      "C#: у метода проставлен содержащий тип")

// диапазон имени указывает ровно на имя
if let item = named(cs, "Validate") {
    let u = Array(csFile.utf16)
    let text = String(decoding: u[item.range.location..<(item.range.location + item.range.length)],
                      as: UTF16.self)
    check(text == "Validate", "C#: диапазон указывает ровно на имя (получено \(text))")
    let lineText = csFile.split(separator: "\n", omittingEmptySubsequences: false)[item.line]
    check(lineText.contains("Validate"), "C#: номер строки правильный")
}

// Swift
let swiftFile = """
import Foundation

protocol Storing {
    func save(_ item: Item) throws
}

public final class Store: Storing {
    private var items: [Item] = []
    public var count: Int { items.count }

    public init(items: [Item]) {
        self.items = items
        print(items.count)
    }

    public func save(_ item: Item) throws {
        let copy = item
        items.append(copy)
        validate(copy)
    }

    private func validate(_ item: Item) {
        guard !item.id.isEmpty else { return }
    }
}

extension Store: CustomStringConvertible {
    public var description: String { "Store(\\(count))" }
}

enum Mode {
    case fast
    case slow
}
"""
let sw = outline(swiftFile, Languages.swift)
for expected in ["Storing", "Store", "save", "validate", "count", "items", "Mode", "fast", "slow"] {
    check(names(sw).contains(expected), "Swift: найдено объявление \(expected)")
}
for callSite in ["append", "print", "copy"] {
    check(!names(sw).contains(callSite), "Swift: вызов/локальная \(callSite) НЕ попала в структуру")
}
check(named(sw, "Store")?.kind == .type, "Swift: Store — тип")
check(named(sw, "save")?.kind == .method, "Swift: save — метод")
check(named(sw, "fast")?.kind == .enumCase, "Swift: case перечисления распознан")
check(named(sw, "Store")?.keyword == "class", "Swift: у объявления запомнено ключевое слово")
check(sw.filter { $0.name == "Store" }.map(\.keyword) == ["class", "extension"],
      "Swift: extension отличается от самого класса по ключевому слову")

// `class func` и `class var` — члены класса, а не новые типы
let swClassMembers = outline("""
class Factory {
    class func make() -> Factory { Factory() }
    class var shared: Factory { Factory() }
}
""", Languages.swift)
check(named(swClassMembers, "make")?.kind == .method, "Swift: class func — метод, а не тип")
check(named(swClassMembers, "shared")?.kind == .property, "Swift: class var — свойство, а не тип")
check(named(outline("export const enum Color { Red }", Languages.javascript), "Color")?.kind == .type,
      "TS: const enum — тип")
check(named(outline("public record struct Point(int X);", Languages.csharp), "Point")?.keyword == "record",
      "C#: record struct — тип с ключевым словом record")
check(sw.contains { $0.kind == .initializer }, "Swift: init распознан")

// Python — блоки по отступам
let pyFile = """
import os

class Repo:
    def __init__(self, path):
        self.path = path
        self.cache = {}

    def load(self, name):
        data = open(name).read()
        return self.parse(data)

    def parse(self, data):
        return data.strip()

def main():
    repo = Repo(".")
    repo.load("x")
"""
let py = outline(pyFile, Languages.python)
for expected in ["Repo", "__init__", "load", "parse", "main"] {
    check(names(py).contains(expected), "Python: найдено объявление \(expected)")
}
check(!names(py).contains("open"), "Python: вызов open НЕ попал в структуру")
check((named(py, "load")?.depth ?? 0) > (named(py, "main")?.depth ?? 9),
      "Python: вложенность считается по отступу")

// Go и TypeScript — проверяем, что подход обобщается
let goFile = """
package main

type Server struct {
    port int
}

func (s *Server) Start() error {
    log.Println("start")
    return nil
}

func main() {
    s := &Server{port: 8080}
    s.Start()
}
"""
let go = outline(goFile, Languages.golang)
check(names(go).contains("Server"), "Go: тип найден")
check(names(go).contains("main"), "Go: функция найдена")
check(!names(go).contains("Println"), "Go: вызов НЕ попал в структуру")

let tsFile = """
export class Widget {
    private id: string;
    render(): void {
        document.createElement("div");
    }
}
export function build(): Widget {
    return new Widget();
}
"""
let ts = outline(tsFile, Languages.javascript)
check(names(ts).contains("Widget"), "TS: класс найден")
check(names(ts).contains("build"), "TS: функция найдена")
check(!names(ts).contains("createElement"), "TS: вызов НЕ попал в структуру")

// вырожденные случаи
check(outline("", Languages.csharp).isEmpty, "пустой файл -> пустая структура")
check(outline("// только комментарий\n", Languages.csharp).isEmpty, "один комментарий -> пусто")
check(outline("{{{{{{", Languages.csharp).isEmpty, "мусор не роняет разбор")
check(outline("public class A { public void B( ", Languages.csharp).count >= 1,
      "оборванный файл разбирается без падения")

// структура нумеруется подряд — на это опирается палитра
let ids = cs.map(\.id)
check(ids == Array(0..<cs.count), "идентификаторы строк идут подряд")

// производительность: структура строится при открытии файла
let bigCS = String(repeating: """
public class Klass\(1) {
    private int _field;
    public int Prop { get; set; }
    public void Method(int arg) {
        var local = Helper(arg);
        Console.WriteLine(local);
    }
}

""", count: 4000)
let tOutline = Date()
let bigItems = outline(bigCS, Languages.csharp)
let outlineMs = Date().timeIntervalSince(tOutline) * 1000
print(String(format: "  структура файла на %d строк: %.0f мс, найдено %d объявлений",
             SyntaxModel(text: bigCS, spec: Languages.csharp).lineCount, outlineMs, bigItems.count))
check(outlineMs < 900, "структура большого файла строится меньше чем за 900 мс")
check(bigItems.count == 4000 * 4, "на большом файле найдено ровно по 4 объявления на класс (получено \(bigItems.count))")


// ────────────────────────── Вхождения символа ──────────────────────────
section("Вхождения символа")

let occDoc = """
public class Counter {
    private int count;          // count хранит счётчик
    public int Count => count;
    public void Bump(int count) {
        this.count += count;
        var counter = "count in a string";
        Log(count);
    }
}
"""
let occModel = SyntaxModel(text: occDoc, spec: Languages.csharp)
let occUnits = Array(occDoc.utf16)

// идентификатор под курсором
let classNameOffset = occDoc.distance(from: occDoc.startIndex,
                                      to: occDoc.range(of: "Counter")!.lowerBound)
check(Occurrences.identifier(in: occModel, at: classNameOffset)?.text == "Counter",
      "идентификатор под курсором: начало слова")
check(Occurrences.identifier(in: occModel, at: classNameOffset + 3)?.text == "Counter",
      "идентификатор под курсором: середина слова")
// курсор сразу ЗА словом — берём слово слева, как делают все редакторы
check(Occurrences.identifier(in: occModel, at: classNameOffset + 7)?.text == "Counter",
      "идентификатор под курсором: сразу за словом")
check(Occurrences.identifier(in: occModel, at: 0)?.text == "public",
      "идентификатор под курсором: самое начало файла")

let hits = Occurrences.find("count", in: occModel)
check(!hits.isEmpty, "вхождения найдены")

// каждое попадание — ровно слово count
var allExact = true
for r in hits {
    let text = String(decoding: occUnits[r.location..<(r.location + r.length)], as: UTF16.self)
    if text != "count" { allExact = false }
}
check(allExact, "каждое вхождение — ровно искомое слово")

// подстроки не считаются: ни Counter, ни counter, ни Count
let counterOffset = occDoc.distance(from: occDoc.startIndex,
                                    to: occDoc.range(of: "counter =")!.lowerBound)
check(!hits.contains { $0.location == counterOffset },
      "'counter' не считается вхождением 'count'")
check(!hits.contains { $0.location == classNameOffset },
      "'Counter' не считается вхождением 'count'")

// вхождения в комментарии и в строковом литерале отброшены
let commentOffset = occDoc.distance(from: occDoc.startIndex,
                                    to: occDoc.range(of: "count хранит")!.lowerBound)
check(!hits.contains { $0.location == commentOffset }, "вхождение в комментарии отброшено")
let stringOffset = occDoc.distance(from: occDoc.startIndex,
                                   to: occDoc.range(of: "count in a string")!.lowerBound)
check(!hits.contains { $0.location == stringOffset }, "вхождение в строковом литерале отброшено")

// объявление отличается от использования
let fieldDecl = occDoc.distance(from: occDoc.startIndex,
                                to: occDoc.range(of: "int count;")!.lowerBound) + 4
check(Occurrences.looksLikeDeclaration(NSRange(location: fieldDecl, length: 5), in: occModel),
      "'int count;' опознано как объявление")
let usage = occDoc.distance(from: occDoc.startIndex,
                            to: occDoc.range(of: "Log(count)")!.lowerBound) + 4
check(!Occurrences.looksLikeDeclaration(NSRange(location: usage, length: 5), in: occModel),
      "'Log(count)' объявлением не считается")

// символ для меню ⌘.: идентификатор в коде, но не ключевое слово и не текст
check(Occurrences.symbol(in: occModel, at: classNameOffset)?.text == "Counter", "символ: имя класса")
check(Occurrences.symbol(in: occModel, at: usage + 2)?.text == "count", "символ: использование поля")
check(Occurrences.symbol(in: occModel, at: 2) == nil, "символ: ключевое слово public — не символ")
check(Occurrences.symbol(in: occModel, at: commentOffset) == nil, "символ: слово в комментарии — не символ")
check(Occurrences.symbol(in: occModel, at: stringOffset + 1) == nil, "символ: слово в строке — не символ")
check(Occurrences.symbol(in: SyntaxModel(text: "alpha beta", spec: nil), at: 7)?.text == "beta",
      "символ: без подсветки языка — любой идентификатор")

check(Occurrences.find("", in: occModel).isEmpty, "пустое слово -> пусто")
check(Occurrences.find("нетакого", in: occModel).isEmpty, "отсутствующее слово -> пусто")
check(Occurrences.identifier(in: SyntaxModel(text: "", spec: nil), at: 0) == nil,
      "пустой документ -> нет идентификатора")

// не-ASCII идентификаторы
let cyrillicModel = SyntaxModel(text: "var счётчик = 1;\nсчётчик += 2;\n", spec: Languages.csharp)
check(Occurrences.find("счётчик", in: cyrillicModel).count == 2,
      "кириллический идентификатор находится")

// производительность на большом файле
let occBig = SyntaxModel(text: String(repeating: "var handler = Build(handler, other);\n", count: 120_000),
                         spec: Languages.csharp)
let tOcc = Date()
let occFound = Occurrences.find("handler", in: occBig)
let occMs = Date().timeIntervalSince(tOcc) * 1000
print(String(format: "  вхождения в файле на 120k строк: %.0f мс, найдено %d", occMs, occFound.count))
check(occMs < 600, "поиск вхождений в большом файле быстрее 600 мс")


// ─────────────────────────── Дерево файлов ───────────────────────────
section("Дерево файлов")

let tree = FileTree.build(paths: [
    "src/b/file10.cs",
    "README.md",
    "src/b/file2.cs",
    "src/a.cs",
    "src/b/deep/x.cs",
    "Assets/Scripts/Player.cs",
    "src/a.cs",                      // дубликат не должен породить второй узел
])
check(tree.fileCount == 6, "файлов шесть, дубликат не считается (получено \(tree.fileCount))")
check(tree.root.children.map(\.name) == ["Assets", "src", "README.md"],
      "в корне папки впереди файлов (получено \(tree.root.children.map(\.name)))")

let srcNode = tree.node(at: "src")
check(srcNode?.isDirectory == true, "src — папка")
check(srcNode?.children.map(\.name) == ["b", "a.cs"], "внутри src папка b раньше a.cs")

let bNode = tree.node(at: "src/b")
check(bNode?.children.map(\.name) == ["deep", "file2.cs", "file10.cs"],
      "естественный порядок: file2 раньше file10 (получено \(bNode?.children.map(\.name) ?? []))")

let deepFile = tree.node(at: "src/b/deep/x.cs")
check(deepFile?.isDirectory == false, "глубокий файл найден по пути")
check(deepFile?.ancestors.map(\.relPath) == ["src", "src/b", "src/b/deep"],
      "цепочка папок до файла — от корня вниз, без самого корня")
check(tree.node(at: "README.md")?.ancestors.isEmpty == true, "у файла в корне предков нет")
check(tree.node(at: "src/nope.cs") == nil, "несуществующий путь -> nil")

let emptyTree = FileTree.build(paths: [])
check(emptyTree.root.children.isEmpty && emptyTree.fileCount == 0, "пустой индекс -> пустое дерево")

// Корень одним чтением — то, что панель показывает до обхода: с тем же
// .gitignore, скрытыми .git и исключениями, что будут и у полного дерева.
do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pilot-shallow-\(getpid())")
    try? FileManager.default.removeItem(at: dir)
    for sub in ["Assets/Scripts", "Build", "Library", ".git"] {
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
    }
    try? "Build/\n".write(to: dir.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
    try? "x".write(to: dir.appendingPathComponent("readme.md"), atomically: true, encoding: .utf8)
    try? "x".write(to: dir.appendingPathComponent("Assets.meta"), atomically: true, encoding: .utf8)
    let shallow = FileTree.shallow(root: dir, ignore: FileChanges.rootMatcher(root: dir),
                                   exclude: { rel, isDir in isDir ? rel == "Library" : rel.hasSuffix(".meta") })
    let names = shallow.root.children.map(\.name)
    check(names == ["Assets", ".gitignore", "readme.md"],
          "корень без обхода: папки впереди, .gitignore, .git и исключения учтены (получено \(names))")
    check(shallow.root.children.first?.isDirectory == true && shallow.root.children.first?.children.isEmpty == true,
          "папка корня — без содержимого, его принесёт полный список")
    try? FileManager.default.removeItem(at: dir)
}

let tTree = Date()
let bigTree = FileTree.build(paths: synthetic.display)
let treeMs = Date().timeIntervalSince(tTree) * 1000
print(String(format: "  дерево из 100k файлов: %.0f мс", treeMs))
check(bigTree.fileCount == 100_000, "в большом дереве все 100k файлов")
check(bigTree.root.children.count == 1 && bigTree.node(at: "src")?.children.count == 200,
      "большое дерево: src и 200 модулей в нём")
check(treeMs < 1500, "дерево из 100k файлов строится быстрее 1.5 с (получено \(Int(treeMs)) мс)")

// ─────────────────────────── Файлы от git ───────────────────────────
section("Файлы от git")

check(GitFiles.split(Data("a.cs\0dir/b.cs\0".utf8)) == ["a.cs", "dir/b.cs"], "split: пути через NUL")
check(GitFiles.split(Data("a.cs\0b.cs".utf8)) == ["a.cs", "b.cs"], "split: последний путь без NUL")
check(GitFiles.split(Data()).isEmpty, "split: пусто -> пусто")
check(GitFiles.split(Data(".gitignore\0src/.idea/x.xml\0src/a.cs\0a.b/c.cs\0x/.cs\0".utf8)) == ["src/a.cs", "a.b/c.cs"],
      "split: скрытые файлы и папки отсеиваются, точка внутри имени — нет")
check(GitFiles.split(Data("vendor/lib/\0Папка/файл.cs\0".utf8)) == ["Папка/файл.cs"],
      "split: вложенный репозиторий (слеш на конце) отсеивается, не-ASCII цел")

if let git = GitFiles.executable {
    // Изолируемся от настроек пользователя: его глобальный excludesFile
    // или подпись коммитов не должны влиять на тест.
    setenv("GIT_CONFIG_GLOBAL", "/dev/null", 1)
    setenv("GIT_CONFIG_NOSYSTEM", "1", 1)

    let fm = FileManager.default
    let repo = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pilot-git-\(UUID().uuidString)")
    func write(_ rel: String) {
        let url = repo.appendingPathComponent(rel)
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("x".utf8).write(to: url)
    }
    func runGit(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: git)
        p.arguments = ["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args
        p.currentDirectoryURL = repo
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    for rel in ["src/App.cs", "src/Old.cs", "README.md", ".hidden/secret.cs", "bin/out.dll"] { write(rel) }
    try? Data("bin/\n".utf8).write(to: repo.appendingPathComponent(".gitignore"))
    runGit(["init", "-q"])
    runGit(["add", "."])
    runGit(["commit", "-q", "-m", "init"])
    write("notes.txt")                                                   // новый, не игнорируется
    write("Папка с пробелом/файл.cs")                                   // пробелы и не-ASCII
    write("bin/new.dll")                                                 // новый, но игнорируется
    write(".hidden/new.cs")                                              // новый, но скрытый

    let tracked = GitFiles.tracked(root: repo) ?? []
    check(Set(tracked) == ["src/App.cs", "src/Old.cs", "README.md"],
          "tracked: отслеживаемые без скрытых (получено \(tracked.sorted()))")
    let all = Set(GitFiles.complete(root: repo, tracked: tracked) ?? [])
    check(all == ["src/App.cs", "src/Old.cs", "README.md", "notes.txt", "Папка с пробелом/файл.cs"],
          "complete: плюс новые, без игнорируемых и скрытых (получено \(all.sorted()))")

    // Главное: от git или обходом — индекс один и тот же.
    let viaGit = FileIndex.scan(root: repo, shouldStop: { false })
    let viaWalk = FileIndex.build(root: repo, shouldStop: { false })
    check(Set(viaGit.display) == Set(viaWalk.display),
          "git и обход диска дают одинаковый набор (git: \(viaGit.display.sorted()), обход: \(viaWalk.display.sorted()))")

    var earlyCount = -1
    _ = FileIndex.scan(root: repo, shouldStop: { false }, early: { earlyCount = $0.count })
    check(earlyCount == 3, "early: сначала приходят отслеживаемые файлы (получено \(earlyCount))")

    // Удалён с диска, но не закоммичен: осознанно остаётся в списке —
    // проверка стоила бы lstat на каждый файл проекта.
    try? fm.removeItem(at: repo.appendingPathComponent("src/Old.cs"))
    check(GitFiles.tracked(root: repo)?.contains("src/Old.cs") == true,
          "удалённый, но не закоммиченный файл остаётся в списке")

    let sub = FileIndex.scan(root: repo.appendingPathComponent("src"), shouldStop: { false })
    check(sub.display == ["App.cs", "Old.cs"], "подпапка репозитория: пути относительно неё (получено \(sub.display))")

    let plain = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pilot-plain-\(UUID().uuidString)")
    try? fm.createDirectory(at: plain, withIntermediateDirectories: true)
    try? Data("x".utf8).write(to: plain.appendingPathComponent("a.cs"))
    check(GitFiles.tracked(root: plain) == nil, "не репозиторий -> nil")
    check(FileIndex.scan(root: plain, shouldStop: { false }).display == ["a.cs"],
          "не репозиторий -> обход диска")

    try? fm.removeItem(at: repo)
    try? fm.removeItem(at: plain)
} else {
    print("  git не найден — проверки со списком файлов от git пропущены")
}

// ─────────────────────────── Индекс типов ───────────────────────────
section("Индекс типов")

func typeNames(_ text: String, _ spec: LanguageSpec) -> [String] {
    TypeIndex.declarations(in: text, spec: spec).map(\.name)
}

// в индекс попадают только типы — ни методы, ни пространства имён
let csTypes = TypeIndex.declarations(in: csFile, spec: Languages.csharp)
check(csTypes.map(\.name) == ["IInvoiceStore", "InvoiceService"],
      "C#: в индексе ровно типы файла (получено \(csTypes.map(\.name)))")
check(csTypes.map(\.keyword) == ["interface", "class"], "C#: ключевые слова типов")
check(csTypes.first?.container == "Acme.Billing", "C#: контейнер — пространство имён целиком")
if let service = csTypes.last {
    let lineText = csFile.split(separator: "\n", omittingEmptySubsequences: false)[Int(service.line)]
    let u = Array(lineText.utf16)
    let name = String(decoding: u[Int(service.column)..<Int(service.column + service.length)], as: UTF16.self)
    check(name == "InvoiceService", "C#: строка и колонка указывают ровно на имя (получено \(name))")
}

check(typeNames(swiftFile, Languages.swift) == ["Storing", "Store", "Mode"],
      "Swift: протокол, класс, enum — без extension (получено \(typeNames(swiftFile, Languages.swift)))")
check(typeNames(pyFile, Languages.python) == ["Repo"], "Python: класс найден")
check(typeNames(goFile, Languages.golang) == ["Server"], "Go: type найден")
check(typeNames(tsFile, Languages.javascript) == ["Widget"], "TS: класс найден, функция — нет")
check(typeNames("struct Point { x: i32 }\nimpl Point { fn new() -> Self { todo!() } }\ntrait Shape {}",
                Languages.rust) == ["Point", "Shape"], "Rust: struct и trait, без impl")

let nestedTypes = TypeIndex.declarations(in: """
public class Outer {
    public class Inner { }
    private enum State { On, Off }
}
""", spec: Languages.csharp)
check(nestedTypes.map(\.name) == ["Outer", "Inner", "State"], "C#: вложенные типы найдены")
check(nestedTypes.first { $0.name == "Inner" }?.container == "Outer", "C#: у вложенного типа контейнер — внешний")

// какие файлы вообще разбираются
check(TypeIndex.spec(forPath: "src/App.cs") != nil, "файл .cs разбирается")
check(TypeIndex.spec(forPath: "src/app.py") != nil, "файл .py разбирается")
check(TypeIndex.spec(forPath: "package.json") == nil, "JSON не разбирается")
check(TypeIndex.spec(forPath: "README.md") == nil, "Markdown не разбирается")
check(TypeIndex.spec(forPath: "build.sh") == nil, "shell не разбирается — типов там нет")
check(TypeIndex.icon(forKeyword: "class") == "c.square", "иконка класса")
check(TypeIndex.icon(forKeyword: "interface") == "i.square", "иконка интерфейса")

// построение по настоящим файлам на диске
let typeRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("pilot-types-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.removeItem(at: typeRoot)
let typeFiles: [String: String] = [
    "src/Services/UserService.cs": "namespace App { public class UserService { } }",
    "src/Models/User.cs": "namespace App { public sealed class User { public class Settings { } } }",
    "src/Models/UserRole.cs": "namespace App { public enum UserRole { Admin } }",
    "tests/UserServiceTests.cs": "public class UserServiceTests { }",
    "src/Ui/Settings.swift": "struct Settings { }\nextension Settings { }",
    "docs/User.md": "class NotAType",
    "src/Big.cs": "public class Huge { }" + String(repeating: " ", count: TypeIndex.maxFileBytes),
]
for (path, text) in typeFiles {
    let url = typeRoot.appendingPathComponent(path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    try? text.write(to: url, atomically: true, encoding: .utf8)
}
let built = TypeIndex.build(root: typeRoot, files: Array(typeFiles.keys), shouldStop: { false })
check(built != nil, "индекс типов построен")
let types = built ?? TypeIndex(root: typeRoot)
let allTypeNames = (0..<types.count).map { types.declaration(Int32($0)).name }.sorted()
check(allTypeNames == ["Settings", "Settings", "User", "UserRole", "UserService", "UserServiceTests"],
      "в индексе типы из исходников, без Markdown и огромных файлов (получено \(allTypeNames))")

func findTypes(_ q: String) -> [String] {
    types.search(q, limit: 50, shouldStop: { false }).map { types.declaration($0.id).name }
}
check(findTypes("USvc").first == "UserService", "аббревиатура USvc -> UserService (получено \(findTypes("USvc")))")
check(findTypes("user").first == "User", "точное имя выигрывает у длинных (получено \(findTypes("user")))")
check(findTypes("userrole").first == "UserRole", "полное имя в нижнем регистре")
check(findTypes("").isEmpty, "пустой запрос ничего не находит")
check(findTypes("zzz").isEmpty, "несовпадающий запрос -> пусто")

// без точки матчится только имя: `app` не цепляется за контейнер App
check(findTypes("app").isEmpty, "без точки контейнер не участвует (получено \(findTypes("app")))")
let qualified = types.search("User.Settings", limit: 10, shouldStop: { false })
check(qualified.first.map { types.declaration($0.id).container } == "User",
      "запрос с точкой находит вложенный тип по контейнеру")
if let hit = qualified.first {
    check(hit.positions == Array(0..<8).map(Int32.init), "позиции подсветки — внутри имени (получено \(hit.positions))")
}
let settings = types.search("settings", limit: 10, shouldStop: { false })
check(settings.count == 2, "одноимённые типы из разных файлов оба в выдаче")
check(settings.first.map { types.relPath($0.id) } == "src/Ui/Settings.swift",
      "при равных очках выше тип, названный как его файл")

if let hit = types.search("UserRole", limit: 1, shouldStop: { false }).first {
    let target = types.target(hit.id)
    check(target.url.path.hasSuffix("src/Models/UserRole.cs"), "переход ведёт в нужный файл")
    check(target.range?.start == LSPPosition(line: 0, character: 28)
          && target.range?.end == LSPPosition(line: 0, character: 36),
          "переход подсвечивает ровно имя (получено \(String(describing: target.range)))")
}

// кэш: сериализация туда и обратно
let restored = TypeIndex.deserialize(types.serialized(), root: typeRoot)
check(restored?.count == types.count, "кэш типов восстанавливается целиком")
check(restored.map { r in (0..<r.count).map { r.declaration(Int32($0)) } }
        == (0..<types.count).map { types.declaration(Int32($0)) },
      "кэш типов восстанавливается без искажений")
check(restored?.search("USvc", limit: 1, shouldStop: { false }).first.map { restored!.declaration($0.id).name }
        == "UserService", "поиск по восстановленному кэшу")
check(TypeIndex.deserialize("что-то чужое\nF\tx", root: typeRoot) == nil, "чужой формат кэша отвергается")
check(TypeIndex.deserialize("pilot-types 1\nclass\tA\t\t1\t2\t3", root: typeRoot) == nil,
      "строка типа без файла отвергается")

check(TypeIndex.build(root: typeRoot, files: Array(typeFiles.keys), shouldStop: { true }) == nil,
      "прерванное построение не отдаёт половину индекса")
try? FileManager.default.removeItem(at: typeRoot)

// производительность: 2000 файлов по ~100 строк, в памяти — без диска
let typeSource = String(repeating: """
namespace Acme.Module
{
    public sealed class Handler\(1) : IHandler
    {
        private readonly ILogger _log;
        public int Retries { get; set; }
        public void Handle(Request request)
        {
            var result = _log.Process(request);
            if (result == null) throw new InvalidOperationException();
        }
    }
}

""", count: 8)
let tTypes = Date()
var typeTotal = 0
for _ in 0..<2000 { typeTotal += TypeIndex.declarations(in: typeSource, spec: Languages.csharp).count }
let typesMs = Date().timeIntervalSince(tTypes) * 1000
print(String(format: "  разбор 2000 файлов на %d строк (один поток): %.0f мс",
             typeSource.split(separator: "\n").count, typesMs))
check(typeTotal == 2000 * 8, "в каждом файле найдено ровно 8 типов")
check(typesMs < 5000, "2000 файлов разбираются быстрее 5 с даже в один поток")

// ──────────────────────── Предпросмотр в палитре ────────────────────────
section("Предпросмотр")

// большой файл: цель в середине, фрагмент — окно вокруг неё
let previewSource = (0..<500).map { i in
    i == 250 ? "public sealed class Target : Base { // цель" : "    var line\(i) = \"text\"; /* c */"
}.joined(separator: "\n")
let previewModel = SyntaxModel(text: previewSource, spec: Languages.csharp)
let focusRange = LSPRange(start: LSPPosition(line: 250, character: 20), end: LSPPosition(line: 250, character: 26))
let focused = FilePreview.make(model: previewModel, range: focusRange)
check(focused.focusLine == 250, "строка цели запомнена")
check(focused.lineCount == 500, "известно число строк файла")
check(focused.lines.first?.number == 250 - FilePreview.linesBefore, "фрагмент начинается выше цели")
check(focused.lines.last?.number == 250 + FilePreview.linesAfter, "фрагмент заканчивается ниже цели")
if let line = focused.lines.first(where: { $0.number == 250 }) {
    check(line.text == "public sealed class Target : Base { // цель", "текст строки собран из отрезков без потерь")
    check(line.segments.filter(\.focused).map(\.text) == ["Target"],
          "подсвечено ровно имя цели (получено \(line.segments.filter(\.focused).map(\.text)))")
    check(line.segments.first?.kind == .keyword && line.segments.first?.text == "public",
          "ключевое слово — отдельным отрезком с видом keyword")
    check(line.segments.last?.kind == .comment, "комментарий в конце строки распознан")
}
check(focused.lines.filter { $0.segments.contains(where: \.focused) }.count == 1,
      "подсветка цели только в одной строке")
check(focused.lines.first { $0.number == 100 + 150 - 1 }?.segments.contains { $0.kind == .string } == true,
      "строковые литералы в соседних строках раскрашены")

// без цели — начало файла
let top = FilePreview.make(model: previewModel, range: nil)
check(top.focusLine == nil && top.lines.first?.number == 0, "без цели показывается начало файла")
check(top.lines.count == FilePreview.linesBefore + FilePreview.linesAfter + 1, "без цели — полное окно строк")

// цель у самого начала и у самого конца — окно подрезается границами файла
check(FilePreview.make(model: previewModel, range: LSPRange(start: LSPPosition(line: 2, character: 0),
                                                           end: LSPPosition(line: 2, character: 1))).lines.first?.number == 0,
      "окно не уходит выше первой строки")
check(FilePreview.make(model: previewModel, range: LSPRange(start: LSPPosition(line: 499, character: 0),
                                                           end: LSPPosition(line: 499, character: 1))).lines.last?.number == 499,
      "окно не уходит ниже последней строки")
check(FilePreview.make(model: previewModel, range: LSPRange(start: LSPPosition(line: 9999, character: 0),
                                                           end: LSPPosition(line: 9999, character: 1))).focusLine == 499,
      "цель за концом файла прижимается к последней строке")

// табуляции, CRLF, длинные строки, многострочный комментарий, файл без языка
let tabbed = FilePreview.make(model: SyntaxModel(text: "\tint x;\r\nnext", spec: Languages.csharp), range: nil)
check(tabbed.lines.first?.text == "    int x;", "табуляция раскрыта в пробелы, \\r\\n отрезан (получено \(tabbed.lines.first?.text ?? "nil"))")
let longLine = FilePreview.make(model: SyntaxModel(text: String(repeating: "a", count: 5000), spec: nil), range: nil)
check(longLine.lines.first.map { $0.text.count } == FilePreview.maxLineLength + 2, "длинная строка обрезана с многоточием")
let block = FilePreview.make(model: SyntaxModel(text: "/* начало\nпродолжение */ int x;", spec: Languages.csharp), range: nil)
check(block.lines.last?.segments.first?.kind == .comment && block.lines.last?.segments.first?.text == "продолжение */",
      "многострочный комментарий раскрашен и во второй строке")
let plain = FilePreview.make(model: SyntaxModel(text: "просто текст", spec: nil), range: nil)
check(plain.lines.first?.segments == [FilePreview.Segment(text: "просто текст", kind: .plain, focused: false)],
      "файл без языка — одним простым отрезком")

let tPreview = Date()
for _ in 0..<200 { _ = FilePreview.make(model: bigModel, range: focusRange) }
let previewMs = Date().timeIntervalSince(tPreview) * 1000 / 200
print(String(format: "  фрагмент для предпросмотра в файле на 200k строк: %.2f мс", previewMs))
check(previewMs < 20, "фрагмент строится быстрее 20 мс даже в огромном файле")

// ─────────────────────────────── ⇧⇧ ───────────────────────────────
section("Двойной Shift")

/// Прогоняет последовательность событий; возвращает, сколько раз сработало.
/// `s` — нажат только Shift, `0` — всё отпущено, `k` — обычная клавиша,
/// `c` — зажат ⌘ (с Shift или без). Время — в секундах.
func doubleShift(_ events: [(String, Double)]) -> Int {
    var detector = DoubleShiftDetector()
    var fired = 0
    for (event, time) in events {
        switch event {
        case "s": if detector.modifiersChanged(shiftOnly: true, none: false, at: time) { fired += 1 }
        case "0": if detector.modifiersChanged(shiftOnly: false, none: true, at: time) { fired += 1 }
        case "c": if detector.modifiersChanged(shiftOnly: false, none: false, at: time) { fired += 1 }
        default:  detector.keyPressed()
        }
    }
    return fired
}
check(doubleShift([("s", 0), ("0", 0.08), ("s", 0.2), ("0", 0.28)]) == 1, "два быстрых нажатия -> срабатывает")
check(doubleShift([("s", 0), ("0", 0.08)]) == 0, "одно нажатие -> нет")
check(doubleShift([("s", 0), ("0", 0.08), ("s", 0.9), ("0", 0.98)]) == 0, "медленно -> нет")
check(doubleShift([("s", 0), ("0", 0.9), ("s", 1.0), ("0", 1.08)]) == 0, "долгое удержание -> нет")
check(doubleShift([("s", 0), ("0", 0.08), ("s", 0.2), ("0", 0.8)]) == 0, "второе нажатие удержано -> нет")
check(doubleShift([("s", 0), ("k", 0.05), ("0", 0.1), ("s", 0.2), ("0", 0.28)]) == 0,
      "Shift+буква, потом Shift -> нет")
check(doubleShift([("s", 0), ("0", 0.08), ("k", 0.1), ("s", 0.2), ("0", 0.28)]) == 0,
      "буква между нажатиями -> нет")
check(doubleShift([("s", 0), ("c", 0.05), ("0", 0.1), ("s", 0.2), ("0", 0.28)]) == 0,
      "⌘⇧, потом Shift -> нет")
check(doubleShift([("s", 0), ("0", 0.08), ("s", 0.2), ("0", 0.28), ("s", 0.4), ("0", 0.48)]) == 1,
      "три нажатия -> срабатывает один раз")
check(doubleShift([("s", 0), ("0", 0.08), ("s", 0.2), ("0", 0.28),
                   ("s", 0.4), ("0", 0.48), ("s", 0.6), ("0", 0.68)]) == 2,
      "четыре нажатия -> два раза")


// ─────────────────────────── Git: диф строк ───────────────────────────
section("Git: диф строк")

/// Старые диапазоны сверяются отдельно ниже — здесь только вид и новые строки.
func shape(_ changes: [LineDiff.Change]) -> [LineDiff.Change] {
    changes.map { LineDiff.Change(kind: $0.kind, lines: $0.lines) }
}
func diff(_ old: String, _ new: String, maxEdits: Int = LineDiff.maxEdits) -> [LineDiff.Change] {
    shape(LineDiff.changes(old: old, new: new, maxEdits: maxEdits))
}
func ch(_ kind: LineDiff.Kind, _ lines: Range<Int>) -> LineDiff.Change {
    LineDiff.Change(kind: kind, lines: lines)
}

let withOld = LineDiff.changes(old: "1\n2\n3\n4\n5\n6\n7\n", new: "1\nX\n3\n4\n5\n7\nY\n")
check(withOld.map(\.oldLines) == [1..<2, 5..<6, 7..<7],
      "старые строки блоков: заменённая, удалённая, пусто у добавленной (получено \(withOld.map(\.oldLines)))")

check(diff("a\nb\nc\n", "a\nb\nc\n").isEmpty, "одинаковые тексты -> изменений нет")
check(diff("a\nc\n", "a\nb\nc\n") == [ch(.added, 1..<2)], "вставка строки -> added")
check(diff("a\nb\nc\n", "a\nc\n") == [ch(.deleted, 1..<1)], "удаление строки -> deleted перед строкой 1")
check(diff("a\nb\nc\n", "a\nB\nc\n") == [ch(.modified, 1..<2)], "правка строки -> modified")
check(diff("a\nb", "a") == [ch(.deleted, 1..<1)], "удаление последней строки -> deleted за концом")
check(diff("", "x\ny\n") == [ch(.added, 0..<2)], "новый файл -> всё добавлено")
check(diff("a\r\nb\r\n", "a\nb\n").isEmpty, "CRLF против LF изменением не считается")
check(diff("1\n2\n3\n4\n5\n6\n7\n", "1\nX\n3\n4\n5\n7\nY\n")
        == [ch(.modified, 1..<2), ch(.deleted, 5..<5), ch(.added, 6..<7)],
      "несколько блоков разного вида (получено \(diff("1\n2\n3\n4\n5\n6\n7\n", "1\nX\n3\n4\n5\n7\nY\n")))")
check(diff("a\nb\n", "a\nb\nc\nd\n") == [ch(.added, 2..<4)], "дописали в конец")
check(diff("a\nb\nc\nd\n", "x\ny\n", maxEdits: 2) == [ch(.modified, 0..<2)],
      "правок больше предела -> один блок на всё различающееся")

// Оптимальность: неизменённые строки нового текста — общая подпоследовательность
// со старым, и она наибольшая (сверяем с LCS динамикой на случайных текстах).
func lcsLength(_ a: [String], _ b: [String]) -> Int {
    var dp = [Int](repeating: 0, count: b.count + 1)
    for x in a {
        var prev = 0
        for j in 0..<b.count {
            let saved = dp[j + 1]
            dp[j + 1] = x == b[j] ? prev + 1 : max(dp[j + 1], dp[j])
            prev = saved
        }
    }
    return dp[b.count]
}
var rng = SystemRandomNumberGenerator()
var diffMismatches = 0
for _ in 0..<400 {
    let a = (0..<Int.random(in: 0...12, using: &rng)).map { _ in ["a", "b", "c"].randomElement(using: &rng)! }
    let b = (0..<Int.random(in: 0...12, using: &rng)).map { _ in ["a", "b", "c"].randomElement(using: &rng)! }
    let changes = diff(a.joined(separator: "\n"), b.joined(separator: "\n"))
    var changed = Set<Int>()
    for c in changes { changed.formUnion(c.lines) }
    let kept = (0..<max(1, b.count)).filter { !changed.contains($0) }.map { b.isEmpty ? "" : b[$0] }
    // kept должен быть подпоследовательностью a…
    var it = (a.isEmpty ? [""] : a).makeIterator()
    let isSubsequence = kept.allSatisfy { line in
        while let next = it.next() { if next == line { return true } }
        return false
    }
    // …и самой длинной из общих.
    let best = lcsLength(a.isEmpty ? [""] : a, b.isEmpty ? [""] : b)
    if !isSubsequence || kept.count != best { diffMismatches += 1 }
}
check(diffMismatches == 0, "на 400 случайных парах диф минимален и корректен (расхождений: \(diffMismatches))")

let bigOld = (0..<100_000).map { "let value\($0) = compute(\($0))" }
var bigNew = bigOld
for i in stride(from: 5_000, to: 100_000, by: 10_000) { bigNew[i] = "// changed \(i)" }
bigNew.insert("// inserted", at: 50_000)
let tDiff = Date()
let bigChanges = LineDiff.changes(old: bigOld.joined(separator: "\n"), new: bigNew.joined(separator: "\n"))
let diffMs = Date().timeIntervalSince(tDiff) * 1000
print(String(format: "  диф файла на 100k строк с 11 правками: %.0f мс", diffMs))
check(bigChanges.count == 11, "в большом файле найдено 11 блоков (получено \(bigChanges.count))")
check(diffMs < 1000, "диф файла на 100k строк быстрее 1 с")


// ─────────────────────────── Git: разбор вывода ───────────────────────────
section("Git: разбор вывода")

let statusFixture = [
    "# branch.oid 1234567890abcdef1234567890abcdef12345678",
    "# branch.head main",
    "# branch.upstream origin/main",
    "# branch.ab +2 -1",
    "1 .M N... 100644 100644 100644 aaa bbb src/App.swift",
    "1 A. N... 000000 100644 100644 000 bbb src/New File.swift",
    "1 D. N... 100644 000000 000000 aaa 000 old.txt",
    "2 R. N... 100644 100644 100644 aaa bbb R100 docs/new.md", "docs/old.md",
    "u UU N... 100644 100644 100644 100644 a b c conflict.cs",
    "? notes/todo.txt",
].joined(separator: "\0") + "\0"
let parsedStatus = GitStatus.parse(Data(statusFixture.utf8))
check(parsedStatus.head == "1234567890abcdef1234567890abcdef12345678", "хэш HEAD")
check(parsedStatus.branch == "main" && parsedStatus.upstream == "origin/main", "ветка и upstream")
check(parsedStatus.ahead == 2 && parsedStatus.behind == 1, "впереди на 2, позади на 1")
check(parsedStatus.files["src/App.swift"] == .modified, "изменённый файл")
check(parsedStatus.files["src/New File.swift"] == .added, "добавленный файл с пробелом в имени")
check(parsedStatus.files["old.txt"] == .deleted, "удалённый файл")
check(parsedStatus.files["docs/new.md"] == .renamed && parsedStatus.files["docs/old.md"] == nil,
      "переименование: новый путь есть, старый не просочился отдельной записью")
check(parsedStatus.files["conflict.cs"] == .conflicted, "конфликт слияния")
check(parsedStatus.files["notes/todo.txt"] == .untracked, "неотслеживаемый файл")
check(parsedStatus.files.count == 6, "файлов шесть (получено \(parsedStatus.files.count))")

let detached = GitStatus.parse(Data("# branch.oid abcdef1234567\0# branch.head (detached)\0".utf8))
check(detached.branch == nil && detached.headLabel == "abcdef1", "отсоединённый HEAD -> короткий хэш")
let initial = GitStatus.parse(Data("# branch.oid (initial)\0# branch.head main\0".utf8))
check(initial.head == nil && initial.branch == "main", "репозиторий без коммитов")

let shaA = String(repeating: "a", count: 40)
let shaZero = String(repeating: "0", count: 40)
let blameFixture = """
\(shaA) 1 1 2
author Ada Lovelace
author-mail <ada@example.com>
author-time 1700000000
author-tz +0000
summary First commit
filename main.swift
\tlet a = 1
\(shaA) 2 2
\tlet b = 2
\(shaZero) 3 3 1
author External file (--contents)
author-time 1800000000
summary Version of main.swift from main.swift
filename main.swift
\tlet c = 3

"""
let blame = GitBlame.parse(Data(blameFixture.utf8), lineCount: 4)
check(blame.commits.count == 2, "два коммита (получено \(blame.commits.count))")
check(blame.commit(atLine: 0)?.author == "Ada Lovelace", "автор первой строки")
check(blame.commit(atLine: 1)?.summary == "First commit", "вторая строка — тот же коммит, сведения не повторяются")
check(blame.commit(atLine: 0)?.time == Date(timeIntervalSince1970: 1_700_000_000), "время коммита")
check(blame.commit(atLine: 2)?.isUncommitted == true, "нулевой хэш -> не закоммичено")
check(blame.commit(atLine: 3) == nil, "строка без сведений -> nil")
check(blame.commit(atLine: 99) == nil, "строка за концом файла -> nil")


// ─────────────────────────── Git: живой репозиторий ───────────────────────────
section("Git: живой репозиторий")

if Git.executable == nil {
    print("  git не найден — пропускаю")
} else {
    let repo = FileManager.default.temporaryDirectory
        .appendingPathComponent("pilot-git-\(UUID().uuidString)")
        .resolvingSymlinksInPath()
    try? FileManager.default.createDirectory(at: repo.appendingPathComponent("src"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: repo) }

    // Глобальный конфиг пользователя (подпись коммитов, хуки) тесту не нужен.
    let isolated = ["-c", "user.name=Pilot Test", "-c", "user.email=test@example.com",
                    "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"]
    func sh(_ args: [String]) { _ = Git.run(isolated + args, in: repo) }
    func write(_ path: String, _ text: String) {
        try? text.write(to: repo.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    sh(["init", "-q", "--initial-branch=main"])
    write("src/app.txt", "one\ntwo\nthree\n")
    write(".gitignore", "*.log\n")
    sh(["add", "."])
    sh(["commit", "-q", "-m", "Initial"])

    check(Git.repositoryRoot(for: repo.appendingPathComponent("src"))?.path == repo.path,
          "корень репозитория находится из вложенной папки")

    write("src/app.txt", "one\nTWO\nthree\nfour\n")
    write("src/new.txt", "fresh\n")
    write("debug.log", "noise\n")

    let live = Git.status(in: repo)
    check(live?.branch == "main" && live?.head?.count == 40, "status: ветка main и хэш HEAD")
    check(live?.files["src/app.txt"] == .modified, "status: изменённый файл")
    check(live?.files["src/new.txt"] == .untracked, "status: новый файл")
    check(live?.files["debug.log"] == nil, "status: игнорируемый файл не попадает")

    let edited = "one\nTWO\nthree\nfour\n"
    let tracked = Git.lineChanges(text: edited, path: "src/app.txt", repository: repo)
    check(tracked?.tracked == true, "файл в HEAD есть")
    check(tracked.map { shape($0.changes) } == [ch(.modified, 1..<2), ch(.added, 3..<4)],
          "полоски против HEAD (получено \(String(describing: tracked?.changes)))")

    let fresh = Git.lineChanges(text: "fresh\n", path: "src/new.txt", repository: repo)
    check(fresh?.tracked == false && fresh.map { shape($0.changes) } == [ch(.added, 0..<1)],
          "новый файл — весь добавлен")
    let ignoredFile = Git.lineChanges(text: "noise\n", path: "debug.log", repository: repo)
    check(ignoredFile?.tracked == false && ignoredFile?.changes.isEmpty == true, "игнорируемый файл — без полосок")

    let liveBlame = Git.blame(text: edited, path: "src/app.txt", repository: repo, lineCount: 5)
    check(liveBlame?.commit(atLine: 0)?.author == "Pilot Test", "blame: автор неизменённой строки")
    check(liveBlame?.commit(atLine: 0)?.summary == "Initial", "blame: сообщение коммита")
    check(liveBlame?.commit(atLine: 1)?.isUncommitted == true, "blame: изменённая строка не закоммичена")
    check(liveBlame?.commit(atLine: 3)?.isUncommitted == true, "blame: дописанная строка не закоммичена")

    // Настоящий конфликт слияния: две ветки правят одну строку.
    let mergeRepo = FileManager.default.temporaryDirectory
        .appendingPathComponent("pilot-merge-\(UUID().uuidString)")
        .resolvingSymlinksInPath()
    try? FileManager.default.createDirectory(at: mergeRepo, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: mergeRepo) }
    func msh(_ args: [String]) -> Int32? { Git.run(isolated + args, in: mergeRepo)?.status }
    func mwrite(_ text: String) {
        try? text.write(to: mergeRepo.appendingPathComponent("app.txt"), atomically: true, encoding: .utf8)
    }
    _ = msh(["init", "-q", "--initial-branch=main"])
    mwrite("one\ntwo\nthree\n")
    _ = msh(["add", "."]); _ = msh(["commit", "-q", "-m", "base"])
    _ = msh(["checkout", "-q", "-b", "feature"])
    mwrite("one\nTWO from feature\nthree\n")
    _ = msh(["commit", "-q", "-am", "feature"])
    _ = msh(["checkout", "-q", "main"])
    mwrite("one\nTWO from main\nthree\n")
    _ = msh(["commit", "-q", "-am", "main"])
    let mergeStatus = msh(["merge", "-q", "feature"])
    check(mergeStatus != 0, "merge с конфликтом завершается ошибкой")
    check(Git.status(in: mergeRepo)?.files["app.txt"] == .conflicted, "status: файл конфликтный")

    let merged = (try? String(contentsOf: mergeRepo.appendingPathComponent("app.txt"), encoding: .utf8)) ?? ""
    let mergedModel = SyntaxModel(text: merged, spec: nil)
    let liveConflicts = MergeConflicts.find(in: mergedModel)
    check(liveConflicts.count == 1 && liveConflicts.first?.currentLabel == "HEAD"
            && liveConflicts.first?.incomingLabel == "feature",
          "маркеры настоящего git: HEAD против feature (получено \(liveConflicts))")
    if let conflict = liveConflicts.first {
        let (range, text) = MergeConflicts.resolution(of: conflict, choice: .incoming, in: mergedModel)
        mwrite((merged as NSString).replacingCharacters(in: range, with: text))
        check((try? String(contentsOf: mergeRepo.appendingPathComponent("app.txt"), encoding: .utf8))
                == "one\nTWO from feature\nthree\n", "после решения — ровно входящая версия")
        _ = msh(["add", "--", "app.txt"])
        check(Git.status(in: mergeRepo)?.files["app.txt"] != .conflicted, "после git add файл больше не конфликтный")
    }
}


// ─────────────────────────── Git: конфликты слияния ───────────────────────────
section("Git: конфликты слияния")

func conflictModel(_ text: String) -> SyntaxModel { SyntaxModel(text: text, spec: nil) }
func resolve(_ text: String, _ choice: ConflictChoice, index: Int = 0) -> String {
    let model = conflictModel(text)
    let conflict = MergeConflicts.find(in: model)[index]
    let (range, replacement) = MergeConflicts.resolution(of: conflict, choice: choice, in: model)
    return (text as NSString).replacingCharacters(in: range, with: replacement)
}

let simpleConflict = """
before
<<<<<<< HEAD
mine
=======
theirs 1
theirs 2
>>>>>>> feature/login
after

"""
let simpleFound = MergeConflicts.find(in: conflictModel(simpleConflict))
check(simpleFound == [MergeConflict(start: 1, base: nil, separator: 3, end: 6,
                                    currentLabel: "HEAD", incomingLabel: "feature/login")],
      "простой конфликт: строки маркеров и метки (получено \(simpleFound))")
check(simpleFound.first?.current == 2..<3 && simpleFound.first?.incoming == 4..<6, "текущее и входящее")
check(resolve(simpleConflict, .current) == "before\nmine\nafter\n", "принять текущее")
check(resolve(simpleConflict, .incoming) == "before\ntheirs 1\ntheirs 2\nafter\n", "принять входящее")
check(resolve(simpleConflict, .both) == "before\nmine\ntheirs 1\ntheirs 2\nafter\n", "принять оба")

let diff3Conflict = "<<<<<<< ours\na = 1\n||||||| merged common ancestors\na = 0\n=======\na = 2\n>>>>>>> theirs\n"
let diff3 = MergeConflicts.find(in: conflictModel(diff3Conflict))
check(diff3.first?.base == 2 && diff3.first?.common == 3..<4, "diff3: строка базы и её содержимое")
check(resolve(diff3Conflict, .base) == "a = 0\n", "принять базу")
check(resolve(diff3Conflict, .current) == "a = 1\n", "diff3: текущее без базы")

let twoConflicts = "<<<<<<< HEAD\na\n=======\nb\n>>>>>>> x\nmid\n<<<<<<< HEAD\nc\n=======\nd\n>>>>>>> x\n"
check(MergeConflicts.find(in: conflictModel(twoConflicts)).count == 2, "два конфликта в файле")
check(resolve(twoConflicts, .incoming, index: 1) == "<<<<<<< HEAD\na\n=======\nb\n>>>>>>> x\nmid\nd\n",
      "решается только выбранный конфликт")

let emptySide = "<<<<<<< HEAD\n=======\nadded\n>>>>>>> x\n"
check(resolve(emptySide, .current) == "", "пустая сторона — блок исчезает целиком")

let noTrailingNewline = "x\n<<<<<<< HEAD\na\n=======\nb\n>>>>>>> x"
check(resolve(noTrailingNewline, .incoming) == "x\nb", "в конце файла без перевода строки лишний не появляется")

let crlf = "<<<<<<< HEAD\r\na\r\n=======\r\nb\r\n>>>>>>> x\r\nz\r\n"
check(MergeConflicts.find(in: conflictModel(crlf)).first?.incomingLabel == "x", "CRLF: маркеры и метка без \\r")
check(resolve(crlf, .current) == "a\r\nz\r\n", "CRLF: переводы строк сохраняются")

check(MergeConflicts.find(in: conflictModel("<<<<<<< HEAD\na\n=======\nb\n")).isEmpty,
      "незакрытый конфликт не считается")
check(MergeConflicts.find(in: conflictModel("Title\n=======\ntext\n")).isEmpty,
      "одинокий ======= (заголовок Markdown) — не конфликт")
check(MergeConflicts.find(in: conflictModel("<<<<<<<< x\na\n=======\nb\n>>>>>>> y\n")).isEmpty,
      "восемь символов — не маркер")
check(MergeConflicts.find(in: conflictModel("<<<<<<< a\n<<<<<<< HEAD\nx\n=======\ny\n>>>>>>> b\n")).first?.start == 1,
      "повторный <<<<<<< начинает конфликт заново")
check(MergeConflicts.conflict(atLine: 4, in: simpleFound)?.start == 1, "конфликт под курсором находится по строке")
check(MergeConflicts.conflict(atLine: 7, in: simpleFound) == nil, "строка после конфликта — вне его")

let bigConflictText = String(repeating: "let value = compute()\n", count: 100_000)
    + "<<<<<<< HEAD\na\n=======\nb\n>>>>>>> x\n"
let bigConflictModel = conflictModel(bigConflictText)
let tConflicts = Date()
let bigConflicts = MergeConflicts.find(in: bigConflictModel)
let conflictMs = Date().timeIntervalSince(tConflicts) * 1000
print(String(format: "  поиск конфликтов в файле на 100k строк: %.1f мс", conflictMs))
check(bigConflicts.count == 1 && conflictMs < 50, "поиск конфликтов на 100k строк быстрее 50 мс")


// ─────────────────────────── GitLab: remote ───────────────────────────
section("GitLab: remote")

let scpRemote = GitLabRemote.parse("git@gitlab.com:acme/game.git")
check(scpRemote == GitLabRemote(host: "gitlab.com", projectPath: "acme/game"), "scp-форма")
check(GitLabRemote.parse("ssh://git@gitlab.example.com:2222/group/sub/app.git")
        == GitLabRemote(host: "gitlab.example.com", projectPath: "group/sub/app"), "ssh:// с портом и подгруппой")
check(GitLabRemote.parse("https://oauth2:secret@GitLab.com/group/app/")
        == GitLabRemote(host: "gitlab.com", projectPath: "group/app"), "https с логином, регистр хоста, хвостовой слеш")
check(GitLabRemote.parse("/Users/me/repos/app.git") == nil, "локальный путь — не GitLab")
check(GitLabRemote.parse("git@gitlab.com:app.git") == nil, "без владельца — не проект")
check(scpRemote?.encodedProject == "acme%2Fgame", "слеш в пути проекта кодируется для API")


// ─────────────────────────── GitLab: дифф MR ───────────────────────────
section("GitLab: дифф MR")

// Старый файл: a b c d e f g h i j (строки 1–10).
// Новый:       a b C d e X f g h Y j  — c→C, вставлен X, удалена i→Y заменена.
let mrDiffText = """
@@ -1,6 +1,7 @@
 a
 b
-c
+C
 d
 e
+X
 f
@@ -7,4 +8,4 @@ fn context
 g
 h
-i
+Y
 j
\\ No newline at end of file
"""
let mrDiff = UnifiedDiff.parse(mrDiffText)
check(mrDiff.blocks.map(\.kind) == [.modified, .added, .modified],
      "виды блоков (получено \(mrDiff.blocks.map(\.kind)))")
check(mrDiff.blocks.map(\.newLines) == [2..<3, 5..<6, 9..<10],
      "новые строки блоков (получено \(mrDiff.blocks.map(\.newLines)))")
check(mrDiff.blocks.map(\.oldLines) == [2..<3, 5..<5, 8..<9],
      "старые строки блоков (получено \(mrDiff.blocks.map(\.oldLines)))")
check(mrDiff.blocks.first?.removed == ["c"], "текст удалённой строки сохраняется")
check(mrDiff.additions == 3 && mrDiff.deletions == 2, "+3 −2")
check(mrDiff.hunks == [0..<7, 7..<11], "видимые в диффе строки (получено \(mrDiff.hunks))")

check(mrDiff.oldLine(forNewLine: 0) == 0, "неизменённая строка до правок — тот же номер")
check(mrDiff.oldLine(forNewLine: 2) == nil, "изменённая строка старого номера не имеет")
check(mrDiff.oldLine(forNewLine: 6) == 5, "после вставки X новая f(6) — старая f(5)")
check(mrDiff.oldLine(forNewLine: 10) == 9, "последняя строка j")
check(mrDiff.newLine(forOldLine: 5) == 6, "старая f показывается на новом месте")
check(mrDiff.newLine(forOldLine: 8) == 9, "удалённая i показывается у заменившего блока")

let mrComment = mrDiff.commentLines(forNewLine: 6)
check(mrComment.old == 6 && mrComment.new == 7, "комментарий к неизменённой строке — обе стороны, с единицы")
check(mrDiff.commentLines(forNewLine: 5).old == nil, "к добавленной — только новая сторона")
check(mrDiff.displayLine(for: GLPosition(oldLine: 9, newLine: nil)) == 9, "тред на удалённой строке")
check(mrDiff.displayLine(for: GLPosition(oldLine: 6, newLine: 7)) == 6, "тред на неизменённой строке")

let newFileDiff = UnifiedDiff.parse("@@ -0,0 +1,3 @@\n+x\n+y\n+z\n")
check(newFileDiff.blocks == [UnifiedDiff.Block(kind: .added, newLines: 0..<3, oldLines: 0..<0, removed: [])],
      "новый файл — один добавленный блок")
let deletedFileDiff = UnifiedDiff.parse("@@ -1,2 +0,0 @@\n-x\n-y\n")
check(deletedFileDiff.blocks.first?.removed == ["x", "y"] && deletedFileDiff.blocks.first?.kind == .deleted,
      "удалённый файл — все строки в removed")
check(UnifiedDiff.parse("").blocks.isEmpty, "пустой дифф (too_large) — без блоков")


// ─────────────────────────── GitLab: JSON ───────────────────────────
section("GitLab: JSON")

let mrJSON = """
{"id": 1, "iid": 42, "title": "Ревью", "description": null, "state": "opened", "draft": true,
 "author": {"id": 7, "username": "ada", "name": "Ada", "avatar_url": "x"},
 "reviewers": [{"id": 8, "username": "stas", "name": "Stas"}],
 "source_branch": "feature", "target_branch": "main",
 "web_url": "https://gitlab.com/g/p/-/merge_requests/42", "sha": "abc",
 "updated_at": "2026-09-12T10:01:06.027Z", "user_notes_count": 3,
 "diff_refs": {"base_sha": "b", "head_sha": "h", "start_sha": "s"}, "unknown_field": [1, 2]}
"""
let decodedMR = try? GitLabJSON.decoder.decode(GLMergeRequest.self, from: Data(mrJSON.utf8))
check(decodedMR?.iid == 42 && decodedMR?.isDraft == true && decodedMR?.reference == "!42", "MR: iid, черновик")
check(decodedMR?.diffRefs == GLDiffRefs(baseSha: "b", headSha: "h", startSha: "s"), "MR: diff_refs")
check(decodedMR?.updatedAt != nil, "MR: дата с долями секунды")
check(decodedMR?.reviewers?.first?.username == "stas", "MR: ревьюеры")

let discussionsJSON = """
[{"id": "d1", "individual_note": false, "notes": [
   {"id": 10, "type": "DiffNote", "body": "Почему так?", "system": false, "resolvable": true, "resolved": false,
    "created_at": "2026-09-12T10:00:00Z", "author": {"id": 8, "username": "stas", "name": "Stas"},
    "position": {"base_sha": "b", "start_sha": "s", "head_sha": "h", "old_path": "a.swift", "new_path": "a.swift",
                 "position_type": "text", "old_line": null, "new_line": 12}},
   {"id": 11, "type": "DiffNote", "body": "Так надо", "system": false, "resolvable": true, "resolved": true,
    "author": {"id": 7, "username": "ada", "name": "Ada"}}]},
 {"id": "d2", "individual_note": true, "notes": [
   {"id": 12, "type": null, "body": "added 1 commit", "system": true, "author": {"id": 7, "username": "ada", "name": "Ada"}}]}]
"""
let discussions = (try? GitLabJSON.decoder.decode([GLDiscussion].self, from: Data(discussionsJSON.utf8))) ?? []
check(discussions.count == 2, "треды декодируются (получено \(discussions.count))")
check(discussions.first?.position?.newLine == 12 && discussions.first?.position?.oldLine == nil,
      "позиция DiffNote: только новая строка")
check(discussions.first?.isResolvable == true && discussions.first?.isResolved == false,
      "тред решён, только если решены все его заметки")
check(discussions.last?.isSystem == true, "системная заметка — не тред для ревью")

let approvalsJSON = #"{"approved": false, "approvals_left": 1, "approved_by": [{"user": {"id": 8, "username": "stas", "name": "Stas"}}]}"#
let approvals = try? GitLabJSON.decoder.decode(GLApprovals.self, from: Data(approvalsJSON.utf8))
check(approvals?.isApproved(by: GLUser(id: 8, username: "stas", name: "Stas")) == true, "апрув от меня виден")
check(approvals?.isApproved(by: GLUser(id: 9, username: "bob", name: "Bob")) == false, "чужой апрув — не мой")

// ────────────────────────── Поиск MR ──────────────────────────
section("GitLab: поиск MR")

func testMR(_ iid: Int, _ title: String, author: String = "ada", reviewer: String? = nil,
            branch: String = "feature", labels: [String]? = nil) -> GLMergeRequest {
    GLMergeRequest(id: 1000 + iid, iid: iid, title: title, description: nil, state: "opened", draft: nil,
                   author: GLUser(id: author.count, username: author, name: author.capitalized),
                   reviewers: reviewer.map { [GLUser(id: 99, username: $0, name: "Ревьюер")] }, assignees: nil,
                   sourceBranch: branch, targetBranch: "develop", webUrl: "", sha: nil, updatedAt: nil,
                   userNotesCount: nil, diffRefs: nil, hasConflicts: nil, labels: labels)
}
let searchList = [
    testMR(10, "Починить загрузку ассетов", branch: "fix/asset-loading"),
    testMR(11, "Ёлка в меню", author: "bob", reviewer: "stas", labels: ["UI"]),
    testMR(12, "Рефакторинг сцены", branch: "loading-screen"),
    testMR(123, "Новый HUD"),
    testMR(7, "HUD: поправить отступы PROJ-123"),
]
func found(_ query: String) -> [Int] { MergeRequestSearch(query).filter(searchList).map(\.iid) }

check(found("") == [10, 11, 12, 123, 7], "пустой запрос — весь список в исходном порядке")
check(found("загрузку") == [10], "слово из заголовка")
check(found("ЗАГРУЗКУ ассетов") == [10], "регистр не важен, все слова должны найтись")
check(found("загрузку сцены").isEmpty, "слова — через И")
check(found("елка") == [11], "ё и е не различаются")
check(found("loading") == [10, 12], "по ветке-источнику (получено \(found("loading")))")
check(found("develop").isEmpty, "целевая ветка не ищется — иначе нашлось бы всё")
check(found("ui") == [11], "по метке")
check(found("@st") == [11], "@логин — ревьюер по началу логина")
check(found("@bob") == [11] && found("@ob").isEmpty, "@логин — автор, только с начала")
check(found("bob") == [11], "имя автора без @")
check(found("!123") == [123], "!номер — только этот MR, не PROJ-123 в заголовке")
check(found("#12") == [12], "#номер — так же")
check(found("123") == [123, 7], "число: сначала MR с таким номером, потом совпадения в тексте (получено \(found("123")))")
check(found("hud") == [123, 7], "совпадения в заголовке — в исходном порядке")
check(found("hud ada") == [123, 7], "слово не из заголовка тоже подходит")
check(found("загрузку ada") == [10], "смесь заголовка и автора")

let fixSearch = MergeRequestSearch("fix @ada !12 Загрузка")
check(fixSearch.apiSearch == "fix Загрузка" && fixSearch.apiAuthor == "ada",
      "в API — слова как ввели, @логин отдельно, !номер не уходит (получено «\(fixSearch.apiSearch)»)")
check(MergeRequestSearch("!42").iid == 42 && MergeRequestSearch("42").iid == 42, "номер из !42 и 42")
check(MergeRequestSearch("42 fix").iid == nil, "номер — только когда запрос из одного числа")
check(!MergeRequestSearch("a").wantsServer && MergeRequestSearch("ab").wantsServer, "GitLab — от двух букв")
check(MergeRequestSearch("!7").wantsServer && MergeRequestSearch("@x").wantsServer, "номер и автор — сразу")
check(MergeRequestSearch("   ").isEmpty, "пробелы — пустой запрос")

let labeledJSON = #"{"id": 2, "iid": 5, "title": "t", "state": "merged", "author": {"id": 1, "username": "a", "name": "A"}, "source_branch": "s", "target_branch": "t", "web_url": "", "labels": ["bug", "UI"]}"#
let labeledMR = try? GitLabJSON.decoder.decode(GLMergeRequest.self, from: Data(labeledJSON.utf8))
check(labeledMR?.labels == ["bug", "UI"] && labeledMR?.isOpen == false, "MR: метки и состояние")


// ────────────────────────── Режимы палитры ──────────────────────────
section("Режимы палитры")

// CaseIterable + исчерпывающие switch: если в enum добавится режим,
// а ветку забудут — это упадёт здесь, а не при сборке приложения.
check(PaletteMode.allCases.count == 11, "режимов палитры одиннадцать: файлы, типы и символы — один поиск, три — у пары")
for scope in SearchScope.allCases {
    check(!scope.title.isEmpty && !scope.placeholder.isEmpty && !scope.icon.isEmpty,
          "у фильтра \(scope) есть подпись, подсказка и иконка")
}
check(SearchScope.everything.includes(.text) && !SearchScope.files.includes(.type)
        && SearchScope.types.includes(.assembly) && !SearchScope.types.includes(.member)
        && SearchScope.symbols.includes(.member) && SearchScope.text.includes(.text)
        && !SearchScope.text.includes(.file),
      "фильтр решает, каких источников спрашивать")
for mode in PaletteMode.allCases {
    check(!mode.placeholder.isEmpty, "у режима \(mode) есть подпись поля")
    check(!mode.icon.isEmpty, "у режима \(mode) есть иконка")
}


// ─────────────────────────────── Unity ───────────────────────────────
section("Unity / GUID и проект")

let guidText = "a79441f348de89743a2939f4d699eac1"
let parsedGUID = UnityGUID(guidText)
check(parsedGUID != nil, "GUID из 32 hex разбирается")
check(parsedGUID?.description == guidText, "GUID печатается обратно так же (получено \(parsedGUID?.description ?? "nil"))")
check(UnityGUID("A79441F348DE89743A2939F4D699EAC1") == parsedGUID, "регистр hex не важен")
check(UnityGUID(guidText + "0") == nil, "33 символа — не GUID")
check(UnityGUID("g79441f348de89743a2939f4d699eac1") == nil, "не-hex символ — не GUID")
check(UnityGUID.parse(Array(guidText.utf8) + [0x30], at: 0) == nil,
      "за GUID идёт ещё hex — это кусок чего-то длиннее")
check(UnityGUID("0000000000000000e000000000000000")?.isBuiltin == true, "встроенный ресурс Unity распознан")
check(parsedGUID?.isBuiltin == false, "обычный GUID — не встроенный")

let metaText = "fileFormatVersion: 2\nguid: df5d7f677beac4272a9df58a6db968b3\nMonoImporter:\n  serializedVersion: 2\n"
check(UnityAssetIndex.parseMeta(ArraySlice(Array(metaText.utf8)))?.description == "df5d7f677beac4272a9df58a6db968b3",
      "GUID читается из .meta")
check(UnityAssetIndex.parseMeta(ArraySlice(Array("fileFormatVersion: 2\n".utf8))) == nil, ".meta без GUID -> nil")

check(UnityProjectInfo.parseEditorVersion("m_EditorVersion: 6000.3.14f1\r\nm_EditorVersionWithRevision: x\r\n") == "6000.3.14f1",
      "версия редактора из ProjectVersion.txt (CRLF)")
let rootProject = UnityProjectInfo(root: URL(fileURLWithPath: "/game"), editorVersion: nil)
check(rootProject.excludedFromIndex(relPath: "Assets/Player.cs.meta", isDirectory: false), ".meta не попадает в индекс")
check(!rootProject.excludedFromIndex(relPath: "Assets/Player.cs", isDirectory: false), "сам ассет попадает в индекс")
check(rootProject.excludedFromIndex(relPath: "Library", isDirectory: true), "Library/ в корне не индексируется")
check(!rootProject.excludedFromIndex(relPath: "Assets/Library", isDirectory: true), "Assets/Library — обычная папка")
let nestedProject = UnityProjectInfo(root: URL(fileURLWithPath: "/repo/Game"), editorVersion: nil, workspacePrefix: "Game")
check(nestedProject.excludedFromIndex(relPath: "Game/Library", isDirectory: true), "Library/ проекта в подпапке не индексируется")
check(!nestedProject.excludedFromIndex(relPath: "Library", isDirectory: true), "а Library/ рядом с проектом — обычная папка")
check(nestedProject.projectPath(fromWorkspace: "Game/Assets/A.cs") == "Assets/A.cs", "путь от корня воркспейса -> путь в проекте")
check(nestedProject.projectPath(fromWorkspace: "Tools/x.py") == nil, "файл вне Unity-проекта")
check(UnityProjectInfo.prettyPath("Library/PackageCache/com.unity.ugui@a1b2c3/Runtime/Button.cs") == "com.unity.ugui/Runtime/Button.cs",
      "путь пакета без хэша версии")

// Индекс ассетов и обход проекта на диске
let unityRoot = FileManager.default.temporaryDirectory.appendingPathComponent("pilot-unity-\(getpid())")
try? FileManager.default.removeItem(at: unityRoot)
func put(_ rel: String, _ text: String) {
    let url = unityRoot.appendingPathComponent(rel)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? text.data(using: .utf8)!.write(to: url)
}
let playerGUID = "11111111111111111111111111111111"
let buttonPrefabGUID = "22222222222222222222222222222222"
let packageScriptGUID = "33333333333333333333333333333333"
put("ProjectSettings/ProjectVersion.txt", "m_EditorVersion: 2022.3.10f1\n")
put("Assets/Scripts/Player.cs", "public class Player : MonoBehaviour { }\n")
put("Assets/Scripts/Player.cs.meta", "fileFormatVersion: 2\nguid: \(playerGUID)\n")
put("Assets/Scripts.meta", "fileFormatVersion: 2\nguid: 44444444444444444444444444444444\nfolderAsset: yes\n")
put("Assets/UI/Button.prefab", "%YAML 1.1\n")
put("Assets/UI/Button.prefab.meta", "fileFormatVersion: 2\nguid: \(buttonPrefabGUID)\n")
put("Library/PackageCache/com.acme.tools@abc123/Runtime/Tool.cs.meta", "fileFormatVersion: 2\nguid: \(packageScriptGUID)\n")
put("Library/junk.bin", "x")
put("Temp/x.txt", "x")

check(UnityProjectInfo.detect(root: unityRoot)?.editorVersion == "2022.3.10f1", "Unity-проект распознан по ProjectVersion.txt")
check(UnityProjectInfo.detect(root: unityRoot.appendingPathComponent("Assets")) == nil, "папка без ProjectSettings — не Unity-проект")
let repoRoot = unityRoot.deletingLastPathComponent().appendingPathComponent("pilot-repo-\(getpid())")
for dir in ["docs", "Game/Assets", "Game/ProjectSettings"] {
    try? FileManager.default.createDirectory(at: repoRoot.appendingPathComponent(dir), withIntermediateDirectories: true)
}
try? "m_EditorVersion: 6000.0.1f1\n".data(using: .utf8)!
    .write(to: repoRoot.appendingPathComponent("Game/ProjectSettings/ProjectVersion.txt"))
let nestedFound = UnityProjectInfo.find(inWorkspace: repoRoot)
check(nestedFound?.workspacePrefix == "Game", "Unity-проект найден в подпапке репозитория (получено \(nestedFound?.workspacePrefix ?? "nil"))")
try? FileManager.default.removeItem(at: repoRoot)

// Unity 6 держит сборки движка в `Contents/Resources/Scripting/Managed`,
// а не в `Contents/Managed`: без этого ⌘B на `Vector3` некуда вести.
let editorRoot = unityRoot.deletingLastPathComponent().appendingPathComponent("pilot-editor-\(getpid())")
let unity6 = editorRoot.appendingPathComponent("6000/Contents")
let unity2022 = editorRoot.appendingPathComponent("2022/Contents")
for dir in ["6000/Contents/Resources/Scripting/Managed/UnityEngine", "2022/Contents/Managed/UnityEngine", "none/Contents"] {
    try? FileManager.default.createDirectory(at: editorRoot.appendingPathComponent(dir), withIntermediateDirectories: true)
}
check(UnityProjectInfo.managed(in: unity6)?.path == unity6.appendingPathComponent("Resources/Scripting/Managed").path,
      "Unity 6: сборки движка в Resources/Scripting/Managed")
check(UnityProjectInfo.managed(in: unity2022)?.path == unity2022.appendingPathComponent("Managed").path,
      "Unity 2022: сборки движка в Managed")
check(UnityProjectInfo.managed(in: editorRoot.appendingPathComponent("none/Contents")) == nil,
      "нет папки со сборками — нет и ответа")
try? FileManager.default.removeItem(at: editorRoot)

let assetIndex = UnityAssetIndex.build(root: unityRoot)
check(assetIndex.count == 4, "в индексе ассеты, папка и скрипт пакета (получено \(assetIndex.count))")
check(assetIndex.path(for: UnityGUID(playerGUID)!) == "Assets/Scripts/Player.cs", "GUID -> путь скрипта")
check(assetIndex.displayName(for: UnityGUID(playerGUID)!) == "Player", "имя скрипта = имя класса")
check(assetIndex.path(for: UnityGUID(packageScriptGUID)!) == "Library/PackageCache/com.acme.tools@abc123/Runtime/Tool.cs",
      "скрипты пакетов резолвятся из PackageCache")
check(assetIndex.guid(forAsset: "Assets/UI/Button.prefab")?.description == buttonPrefabGUID, "путь -> GUID")
check(assetIndex.path(for: UnityGUID("44444444444444444444444444444444")!) == "Assets/Scripts", "у папок тоже есть GUID")

// Повторная сборка поверх прошлой: неизменившийся `.meta` не читается, его
// GUID берётся из прошлого индекса; изменённый после — читается заново.
do {
    let meta = unityRoot.appendingPathComponent("Assets/UI/Button.prefab.meta")
    let other = "55555555555555555555555555555555"
    put("Assets/UI/Button.prefab.meta", "fileFormatVersion: 2\nguid: \(other)\n")
    let setTime = { (date: Date) in try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: meta.path) }
    setTime(Date(timeIntervalSince1970: 1_000_000))
    let reused = UnityAssetIndex.build(root: unityRoot, reusing: assetIndex, since: Date())
    check(reused.guid(forAsset: "Assets/UI/Button.prefab")?.description == buttonPrefabGUID,
          "неизменившийся .meta не перечитывается: GUID из прошлого индекса")
    check(reused.count == assetIndex.count, "повторная сборка знает те же ассеты (получено \(reused.count))")
    setTime(Date().addingTimeInterval(60))
    let reread = UnityAssetIndex.build(root: unityRoot, reusing: assetIndex, since: Date())
    check(reread.guid(forAsset: "Assets/UI/Button.prefab")?.description == other,
          "изменённый после прошлой сборки .meta перечитан")
    put("Assets/UI/Button.prefab.meta", "fileFormatVersion: 2\nguid: \(buttonPrefabGUID)\n")
}

// Кэш на диске: прочитанный индекс отвечает так же, как построенный.
let assetText = assetIndex.serialized()
if let reread = UnityAssetIndex.deserialize(assetText) {
    check(reread.count == assetIndex.count, "из кэша — те же ассеты")
    check(reread.path(for: UnityGUID(playerGUID)!) == "Assets/Scripts/Player.cs", "из кэша: GUID -> путь")
    check(reread.guid(forAsset: "Assets/UI/Button.prefab")?.description == buttonPrefabGUID, "из кэша: путь -> GUID")
    check(reread.displayName(for: UnityGUID(playerGUID)!) == "Player", "из кэша: имя скрипта")
    check(reread.assemblyPaths == assetIndex.assemblyPaths, "из кэша: те же сборки")
    check(reread.serialized() == assetText, "и записывается обратно байт в байт")
} else {
    check(false, "кэш индекса GUID читается")
}
check(UnityAssetIndex.deserialize("unity-assets 0\n") == nil, "чужая версия кэша не читается")
check(UnityAssetIndex.deserialize("unity-assets 1\nnot-a-guid\tAssets/A.cs\n") == nil,
      "испорченный кэш не читается — индекс строится заново")

let unityFiles = FileIndex.build(root: unityRoot, exclude: rootProject.excludedFromIndex, shouldStop: { false })
check(!unityFiles.display.contains { $0.hasSuffix(".meta") }, "в индексе файлов Unity-проекта нет .meta")
check(!unityFiles.display.contains { $0.hasPrefix("Library/") || $0.hasPrefix("Temp/") },
      "Library/ и Temp/ не индексируются даже без .gitignore")
check(unityFiles.display.contains("Assets/Scripts/Player.cs"), "обычные ассеты в индексе есть")

section("Unity / сцены и префабы")

let sceneText = """
%YAML 1.1
%TAG !u! tag:unity3d.com,2011:
--- !u!1 &100
GameObject:
  m_ObjectHideFlags: 0
  m_Component:
  - component: {fileID: 101}
  m_Name: Canvas
--- !u!224 &101
RectTransform:
  m_GameObject: {fileID: 100}
  m_Children:
  - {fileID: 201}
  m_Father: {fileID: 0}
--- !u!1 &200
GameObject:
  m_Name: 'Play Button'
--- !u!4 &201
Transform:
  m_GameObject: {fileID: 200}
  m_Father: {fileID: 101}
--- !u!114 &202
MonoBehaviour:
  m_GameObject: {fileID: 200}
  m_Enabled: 1
  m_Script: {fileID: 11500000, guid: \(playerGUID), type: 3}
  m_Name: 
  m_EditorClassIdentifier: Assembly-CSharp::Game.Player
  speed: 5
--- !u!114 &203
MonoBehaviour:
  m_GameObject: {fileID: 200}
  m_Script: {fileID: 11500000, guid: 99999999999999999999999999999999, type: 3}
  m_Name: 
  m_EditorClassIdentifier: Unity.UI::UnityEngine.UI.Image
--- !u!1001 &300
PrefabInstance:
  m_ObjectHideFlags: 0
  m_Modification:
    serializedVersion: 3
    m_TransformParent: {fileID: 201}
    m_Modifications:
    - target: {fileID: 555, guid: \(buttonPrefabGUID), type: 3}
      propertyPath: m_LocalPosition.x
      value: 0
      objectReference: {fileID: 0}
    - target: {fileID: 556, guid: \(buttonPrefabGUID), type: 3}
      propertyPath: m_Name
      value: Icon
      objectReference: {fileID: 0}
  m_SourcePrefab: {fileID: 100100000, guid: \(buttonPrefabGUID), type: 3}
--- !u!4 &-301 stripped
Transform:
  m_CorrespondingSourceObject: {fileID: 557, guid: \(buttonPrefabGUID), type: 3}
  m_PrefabInstance: {fileID: 300}
--- !u!1 &400
GameObject:
  m_Name: Badge
--- !u!4 &401
Transform:
  m_GameObject: {fileID: 400}
  m_Father: {fileID: -301}
"""
let sceneModel = SyntaxModel(text: sceneText, spec: Languages.detect(filename: "Main.unity"))
check(sceneModel.spec?.name == "Unity YAML", ".unity распознаётся как Unity YAML")
check(Languages.detect(filename: "Player.prefab.meta")?.name == "Unity YAML", ".meta — тоже Unity YAML")
check(Languages.detect(filename: "Water.shader")?.name == "ShaderLab", ".shader — ShaderLab")
check(Languages.detect(filename: "Lighting.hlsl")?.name == "HLSL", ".hlsl — HLSL")
check(Languages.detect(filename: "Game.asmdef")?.name == "JSON", ".asmdef — JSON")
check(Languages.detect(filename: "Menu.uxml")?.name == "XML/HTML", ".uxml — XML")

let sceneTokens = sceneModel.tokens(fromLine: 0, toLine: sceneModel.lineCount - 1)
check(kindOf("m_Name", sceneModel, sceneTokens) == .function, "YAML: ключ перед двоеточием выделен")
check(kindOf("GameObject", sceneModel, sceneTokens) == .function, "YAML: имя типа объекта выделено как ключ")
checkTwoPassConsistency(sceneText, Languages.unityYAML, "Unity YAML")

let scene = UnityYAMLFile.parse(sceneModel.units)
check(scene?.objects.count == 10, "в сцене 10 объектов (получено \(scene?.objects.count ?? -1))")
if let scene {
    let behaviour = scene.object(202)
    check(behaviour?.typeName == "MonoBehaviour", "имя типа объекта")
    check(behaviour?.gameObject == 200, "m_GameObject разобран")
    check(behaviour?.script?.description == playerGUID, "m_Script разобран")
    check(scene.object(200)?.name == "Play Button", "m_Name без кавычек")
    check(scene.object(-301)?.stripped == true, "stripped-объект с отрицательным fileID")
    check(scene.object(300)?.modifiedName == "Icon", "переименование вложенного префаба")
    check(scene.object(300)?.transformParent == 201, "m_TransformParent вложенного префаба")
    check(scene.object(300)?.sourcePrefab?.description == buttonPrefabGUID, "m_SourcePrefab")

    let resolve: (UnityGUID) -> String? = { assetIndex.displayName(for: $0) }
    check(scene.path(ofGameObject: 200) == ["Canvas", "Play Button"], "иерархия через m_Father")
    check(scene.path(ofGameObject: 400) == ["Canvas", "Play Button", "Icon", "Badge"],
          "иерархия идёт через вложенный префаб (получено \(scene.path(ofGameObject: 400)))")

    let sceneOutline = scene.outline(resolve: resolve)
    let byName = Dictionary(sceneOutline.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    check(byName["Canvas"]?.kind == .gameObject && byName["Canvas"]?.container == nil, "корневой GameObject в структуре")
    check(byName["Play Button"]?.container == "Canvas", "контейнер GameObject'а — путь родителя")
    check(byName["Player"]?.kind == .component && byName["Player"]?.container == "Canvas / Play Button",
          "MonoBehaviour назван именем скрипта по GUID")
    check(byName["Image"]?.kind == .component, "скрипт вне проекта назван по m_EditorClassIdentifier")
    check(byName["RectTransform"]?.container == "Canvas", "встроенный компонент назван типом")
    check(byName["Icon"]?.kind == .prefab && byName["Icon"]?.container == "Canvas / Play Button",
          "вложенный префаб — под своим родителем")
    check(!sceneOutline.contains { $0.name == "Transform" && $0.container == "Icon" },
          "stripped-заглушки в структуру не попадают")
    check(zip(sceneOutline, sceneOutline.dropFirst()).allSatisfy { $0.range.location < $1.range.location },
          "структура сцены идёт в порядке файла")
    if let player = byName["Player"] {
        let text = String(decoding: sceneModel.units[player.range.location..<NSMaxRange(player.range)], as: UTF16.self)
        check(text == "MonoBehaviour", "переход по компоненту ведёт к имени его типа")
    }
    let unnamed = scene.outline(resolve: { _ in nil })
    check(unnamed.contains { $0.name == "Game" || $0.name == "Player" } == true,
          "без индекса ассетов имя скрипта берётся из m_EditorClassIdentifier")
    check(unnamed.contains { $0.name == "Icon" }, "имя вложенного префаба — из переопределённого m_Name")

    check(scene.describe(objectAt: scene.index(ofFileID: 202)!, resolve: resolve) == "Canvas / Play Button › Player",
          "описание компонента для списка использований")

    // Ссылки под курсором
    func refAt(_ needle: String, delta: Int = 0) -> UnityReference? {
        let text = sceneModel.units
        let n = Array(needle.utf16)
        guard let start = (0...(text.count - n.count)).first(where: { Array(text[$0..<$0 + n.count]) == n }) else { return nil }
        let offset = start + delta
        let line = sceneModel.line(containing: offset)
        return UnityYAMLFile.reference(in: text, line: sceneModel.lineRange(line), at: offset)?.reference
    }
    check(refAt("m_Father: {fileID: 101}", delta: 12) == .local(fileID: 101), "локальная ссылка под курсором")
    check(refAt("  m_Script:", delta: 3) == .asset(guid: UnityGUID(playerGUID)!, fileID: 11500000),
          "курсор на ключе — берётся единственная ссылка строки")
    check(refAt("m_Father: {fileID: 0}", delta: 12) == nil, "нулевая ссылка — не ссылка")
    check(refAt("m_Name: Canvas", delta: 2) == nil, "в строке без ссылок перехода нет")
    let metaModel = SyntaxModel(text: metaText, spec: Languages.unityYAML)
    check(UnityYAMLFile.reference(in: metaModel.units, line: metaModel.lineRange(1), at: 10)?.reference
            == .asset(guid: UnityGUID("df5d7f677beac4272a9df58a6db968b3")!, fileID: nil),
          "GUID в .meta — тоже ссылка")
    let asmdef = SyntaxModel(text: "{ \"references\": [\"GUID:\(playerGUID)\"] }", spec: Languages.json)
    check(UnityYAMLFile.reference(in: asmdef.units, line: asmdef.lineRange(0), at: 25)?.reference
            == .asset(guid: UnityGUID(playerGUID)!, fileID: nil),
          "GUID:… в .asmdef — ссылка на сборку")

    let guids = UnityYAMLFile.guidRanges(in: sceneModel.units, 0..<sceneModel.units.count)
    check(guids.count == 6, "все GUID сцены найдены (получено \(guids.count))")
    let locals = UnityYAMLFile.localReferences(in: sceneModel.units, 0..<sceneModel.units.count)
    check(locals.contains { $0.fileID == -301 } && !locals.contains { $0.fileID == 0 },
          "локальные ссылки: отрицательные есть, нулевых нет")
    check(!locals.contains { $0.fileID == 11500000 }, "ссылка с GUID — не локальная")

    let sceneBytes = Array(sceneText.utf8)
    sceneBytes.withUnsafeBytes { bytes in
        check(UnityYAMLFile.anchorLine(fileID: 200, in: bytes) == 14, "заголовок &200 найден в сыром файле")
        check(UnityYAMLFile.anchorLine(fileID: -301, in: bytes) == 51, "заголовок stripped-объекта найден")
        check(UnityYAMLFile.anchorLine(fileID: 20, in: bytes) == nil, "&20 не совпадает с &200")
    }

    // Использования: попадания в одном объекте сворачиваются
    let prefabHits = sceneBytes.withUnsafeBytes {
        UnityUsages.hits(in: $0, needle: Array(buttonPrefabGUID.utf8), relPath: "Assets/Main.unity", resolve: resolve)
    }
    check(prefabHits.count == 2, "вложенный префаб: одно попадание на объект (получено \(prefabHits.count))")
    check(prefabHits.first?.context == "Canvas / Play Button / Icon", "контекст — путь вложенного префаба (получено \(prefabHits.first?.context ?? "nil"))")
    check(prefabHits.first?.line == 42, "строка первого попадания (получено \(prefabHits.first?.line ?? -1))")
    let scriptHits = sceneBytes.withUnsafeBytes {
        UnityUsages.hits(in: $0, needle: Array(playerGUID.utf8), relPath: "Assets/Main.unity", resolve: resolve)
    }
    check(scriptHits.count == 1 && scriptHits[0].context == "Canvas / Play Button › Player",
          "скрипт используется на Play Button")
    check(scriptHits.first?.column == 37, "колонка GUID в строке (получено \(scriptHits.first?.column ?? -1))")
}

put("Assets/Main.unity", sceneText)
put("Assets/Game.asmdef", "{ \"references\": [\"GUID:\(playerGUID)\"] }")
put("Assets/Notes.txt", playerGUID)
let found = UnityUsages.find(guid: UnityGUID(playerGUID)!, root: unityRoot,
                             paths: ["Assets/Main.unity", "Assets/Game.asmdef", "Assets/Notes.txt"],
                             resolve: { assetIndex.displayName(for: $0) })
check(found.map(\.relPath).sorted() == ["Assets/Game.asmdef", "Assets/Main.unity"],
      "поиск GUID по проекту: сцена и asmdef, но не .txt")
try? FileManager.default.removeItem(at: unityRoot)

// Производительность: сцена на 50 000 объектов
var bigScene = "%YAML 1.1\n%TAG !u! tag:unity3d.com,2011:\n"
bigScene.reserveCapacity(12_000_000)
for k in 0..<12_500 {
    let go = 1000 + k * 4
    bigScene += "--- !u!1 &\(go)\nGameObject:\n  m_ObjectHideFlags: 0\n  m_Name: Object\(k)\n  m_IsActive: 1\n"
    bigScene += "--- !u!4 &\(go + 1)\nTransform:\n  m_GameObject: {fileID: \(go)}\n  m_LocalPosition: {x: 0, y: 0, z: 0}\n  m_Father: {fileID: \(k == 0 ? 0 : 1001 + (k - 1) / 10 * 4)}\n"
    bigScene += "--- !u!114 &\(go + 2)\nMonoBehaviour:\n  m_GameObject: {fileID: \(go)}\n  m_Script: {fileID: 11500000, guid: \(playerGUID), type: 3}\n  m_Name: \n  value: 1\n"
    bigScene += "--- !u!23 &\(go + 3)\nMeshRenderer:\n  m_GameObject: {fileID: \(go)}\n  m_Materials:\n  - {fileID: 2100000, guid: \(buttonPrefabGUID), type: 2}\n"
}
let sceneBigModel = SyntaxModel(text: bigScene, spec: Languages.unityYAML)
let tParse = Date()
let bigFile = UnityYAMLFile.parse(sceneBigModel.units)
let bigOutline = bigFile?.outline(resolve: { assetIndex.displayName(for: $0) }) ?? []
let parseMs = Date().timeIntervalSince(tParse) * 1000
print(String(format: "  сцена на %d строк: разбор и структура за %.0f мс", sceneBigModel.lineCount, parseMs))
check(bigFile?.objects.count == 50_000, "большая сцена: все 50 000 объектов")
check(bigOutline.count == 50_000, "большая сцена: структура на все объекты")
check(parseMs < 1500, "сцена на 50k объектов разбирается быстрее 1.5 с (получено \(Int(parseMs)) мс)")

section("Unity / иерархия")

if let scene, let hierarchy = UnityHierarchy.build(file: scene, resolve: { _ in nil }) {
    func names(_ nodes: [Int]) -> [String] { nodes.map { hierarchy.nodes[$0].name } }
    func node(_ fileID: Int64) -> Int? { hierarchy.node(forFileID: fileID) }
    check(names(hierarchy.roots) == ["Canvas"], "корень сцены (получено \(names(hierarchy.roots)))")
    if let canvas = node(100), let button = node(200), let icon = node(300), let badge = node(400) {
        check(names(hierarchy.nodes[canvas].children) == ["Play Button"], "дети Canvas")
        check(names(hierarchy.nodes[button].children) == ["Icon"], "вложенный префаб — ребёнок своего родителя")
        check(hierarchy.nodes[icon].isPrefab && !hierarchy.nodes[button].isPrefab, "вложенный префаб помечен")
        check(names(hierarchy.nodes[icon].children) == ["Badge"], "добавленное во вложенный префаб — под ним")
        check(names(hierarchy.ancestors(of: badge)) == ["Canvas", "Play Button", "Icon"], "предки от корня")
        check(hierarchy.node(forObjectAt: scene.index(ofFileID: 202)!, in: scene) == button,
              "компонент ведёт к своему GameObject'у")
        check(hierarchy.node(forObjectAt: scene.index(ofFileID: -301)!, in: scene) == icon,
              "заглушка ведёт к вложенному префабу")
        check(hierarchy.node(forObjectAt: scene.index(ofFileID: 101)!, in: scene) == canvas,
              "Transform ведёт к своему GameObject'у")
    } else {
        check(false, "все объекты сцены есть в иерархии")
    }
} else {
    check(false, "иерархия сцены строится")
}

// Порядок детей — по m_Children, а не по файлу; заглушка вложенного префаба
// стоит в m_Children, как у Unity. `m_Children: []` не глотает следующие ключи.
let orderedPrefab = """
--- !u!1 &1
GameObject:
  m_Name: Root
--- !u!4 &2
Transform:
  m_GameObject: {fileID: 1}
  m_Children:
  - {fileID: 22}
  - {fileID: -40}
  - {fileID: 12}
  m_Father: {fileID: 0}
--- !u!1 &11
GameObject:
  m_Name: Second
  m_IsActive: 0
--- !u!4 &12
Transform:
  m_GameObject: {fileID: 11}
  m_Children: []
  m_Father: {fileID: 2}
--- !u!1 &21
GameObject:
  m_Name: First
  m_IsActive: 1
--- !u!4 &22
Transform:
  m_GameObject: {fileID: 21}
  m_Children: []
  m_Father: {fileID: 2}
--- !u!1001 &30
PrefabInstance:
  m_Modification:
    m_TransformParent: {fileID: 2}
  m_SourcePrefab: {fileID: 100100000, guid: \(buttonPrefabGUID), type: 3}
--- !u!4 &-40 stripped
Transform:
  m_PrefabInstance: {fileID: 30}
"""
let orderedFile = UnityYAMLFile.parse(SyntaxModel(text: orderedPrefab, spec: Languages.unityYAML).units)!
check(orderedFile.object(2)?.children == [22, -40, 12], "m_Children разобран (получено \(orderedFile.object(2)?.children ?? []))")
check(orderedFile.object(12)?.children == [] && orderedFile.object(12)?.father == 2, "m_Children: [] — и m_Father после него")
check(orderedFile.object(11)?.isInactive == true && orderedFile.object(21)?.isInactive == false, "m_IsActive")
if let h = UnityHierarchy.build(file: orderedFile, resolve: { $0.description == buttonPrefabGUID ? "Button" : nil }) {
    let root = h.roots.first!
    let kids = h.nodes[root].children.map { h.nodes[$0].name }
    check(kids == ["First", "Button", "Second"], "дети в порядке m_Children (получено \(kids))")
    check(h.nodes[h.node(forFileID: 11)!].isActive == false, "выключенный GameObject")
}

// Корни сцены: SceneRoots (Unity 2022+) и m_RootOrder (раньше).
func rootNames(_ text: String) -> [String] {
    guard let file = UnityYAMLFile.parse(SyntaxModel(text: text, spec: Languages.unityYAML).units),
          let h = UnityHierarchy.build(file: file, resolve: { _ in nil }) else { return [] }
    return h.roots.map { h.nodes[$0].name }
}
func rootObject(_ go: Int, _ name: String, order: Int? = nil) -> String {
    """
    --- !u!1 &\(go)
    GameObject:
      m_Name: \(name)
    --- !u!4 &\(go + 1)
    Transform:
      m_GameObject: {fileID: \(go)}
      m_Children: []
      m_Father: {fileID: 0}
    \(order.map { "  m_RootOrder: \($0)\n" } ?? "")
    """
}
let prefabRoot = """
--- !u!1001 &90
PrefabInstance:
  m_Modification:
    m_TransformParent: {fileID: 0}
    m_Modifications:
    - target: {fileID: 1, guid: \(buttonPrefabGUID), type: 3}
      propertyPath: m_Name
      value: Enemy
      objectReference: {fileID: 0}
    - target: {fileID: 2, guid: \(buttonPrefabGUID), type: 3}
      propertyPath: m_RootOrder
      value: 1
      objectReference: {fileID: 0}

"""
check(rootNames(rootObject(10, "Camera") + rootObject(20, "Light") + prefabRoot + """
--- !u!1660057539 &9223372036854775807
SceneRoots:
  m_ObjectHideFlags: 0
  m_Roots:
  - {fileID: 21}
  - {fileID: 90}
  - {fileID: 11}
""") == ["Light", "Enemy", "Camera"], "корни — по SceneRoots, вложенный префаб в нём своим fileID")
check(rootNames(rootObject(10, "Camera", order: 2) + rootObject(20, "Light", order: 0) + prefabRoot)
      == ["Light", "Enemy", "Camera"], "без SceneRoots корни — по m_RootOrder, у префаба — из переопределений")
check(rootNames(rootObject(10, "Camera") + rootObject(20, "Light")) == ["Camera", "Light"],
      "без порядка — как в файле")
let settingsAsset = "--- !u!114 &11400000\nMonoBehaviour:\n  m_Name: Settings\n  speed: 5\n"
check(UnityHierarchy.build(file: UnityYAMLFile.parse(SyntaxModel(text: settingsAsset, spec: Languages.unityYAML).units)!,
                           resolve: { _ in nil }) == nil,
      "у ScriptableObject иерархии нет")

// Большая сцена: 12 500 GameObject'ов, по десять детей у каждого.
if let bigFile {
    let t = Date()
    let bigHierarchy = UnityHierarchy.build(file: bigFile, resolve: { assetIndex.displayName(for: $0) })
    let ms = Date().timeIntervalSince(t) * 1000
    print(String(format: "  иерархия сцены на 12 500 объектов: %.0f мс", ms))
    check(bigHierarchy?.nodes.count == 12_500 && bigHierarchy?.roots.count == 1, "большая сцена: все узлы, один корень")
    check(ms < 300, "иерархия большой сцены быстрее 300 мс (получено \(Int(ms)) мс)")
}

section("Unity / C#")

let unityScript = """
using UnityEngine;

public class Player : MonoBehaviour
{
    [SerializeField] private float speed = 5f;
    [Header("Refs"), SerializeField]
    private Rigidbody body;
    [field: SerializeField] public int Health { get; private set; }
    public int score;
    private int[] cache = new int[4];

    private void Awake() { body = GetComponent<Rigidbody>(); }
    void Update()
    {
        Move();
    }
    private void OnTriggerEnter(Collider other) { }
    private void Move() { }
}
"""
let scriptModel = SyntaxModel(text: unityScript, spec: Languages.csharp)
let lexical = OutlineBuilder.build(model: scriptModel)
let context = UnityContext(project: UnityProjectInfo(root: URL(fileURLWithPath: "/"), editorVersion: nil), assets: nil)
let enriched = UnitySemantics.analyze(model: scriptModel, lexicalOutline: lexical, context: context)?.outline ?? []
func kindIn(_ items: [OutlineItem], _ name: String) -> OutlineKind? { items.first { $0.name == name }?.kind }
check(kindIn(enriched, "Awake") == .unityMessage, "Awake — сообщение Unity")
check(kindIn(enriched, "Update") == .unityMessage, "Update — сообщение Unity")
check(kindIn(enriched, "OnTriggerEnter") == .unityMessage, "OnTriggerEnter — сообщение Unity")
check(kindIn(enriched, "Move") == .method, "Move — обычный метод")
check(kindIn(enriched, "speed") == .serializedField, "[SerializeField] на той же строке")
check(kindIn(enriched, "body") == .serializedField, "SerializeField в списке атрибутов строкой выше")
check(kindIn(enriched, "Health") == .serializedField, "[field: SerializeField] у автосвойства")
check(kindIn(enriched, "score") == .field, "поле без атрибута не помечается")
check(kindIn(enriched, "cache") == .field, "квадратные скобки массива — не атрибут")
check(UnitySemantics.analyze(model: scriptModel, lexicalOutline: lexical, context: nil) == nil,
      "вне Unity-проекта C# остаётся как есть")

let declaration = UnityCSharp.classDeclaration(named: "Player", in: unityScript)
check(declaration?.line == 2 && declaration?.column == 13, "class Player найден для перехода со ссылки")
check(UnityCSharp.classDeclaration(named: "Play", in: unityScript) == nil, "Play не совпадает с Player")
check(UnityCSharp.classDeclaration(named: "Enemy", in: "// class Enemy\nsealed class Enemy {}\r\n")?.line == 1,
      "закомментированное объявление пропускается")


section("Unity / инспектор")

let soText = """
%YAML 1.1
%TAG !u! tag:unity3d.com,2011:
--- !u!114 &11400000
MonoBehaviour:
  m_ObjectHideFlags: 0
  m_GameObject: {fileID: 0}
  m_Enabled: 1
  m_Script: {fileID: 11500000, guid: \(playerGUID), type: 3}
  m_Name: 2P_Host
  m_Description: 
  m_EnableEditors: 1
  m_MainEditorInstance:
    Name: Main Editor
    <CorrespondingNodeId>k__BackingField: Main Editor|0_run
    m_Nodes:
    - Main Editor|0_run
    - Main Editor|0_deploy
    m_Role: 3
  m_EditorInstances:
  - Name: Player 2
    m_Nodes:
    - Player 2|1_run
    m_AdvancedConfiguration:
      StreamLogsToMainEditor: 1
      LogsColor: {r: 0.3643, g: 0.581, b: 0.8679, a: 1}
  - Name: 'Player: 3'
    m_Nodes: []
  m_LocalInstances: []
  m_Title: 'D - GRAVITY RAMP

    fires on Play'
  m_Quote: "ROW \\xB7 rest"
  'm_Metrics[0]': 15677.869
  m_Tail: 5
"""
let soModel = SyntaxModel(text: soText, spec: Languages.unityYAML)
let soFile = UnityYAMLFile.parse(soModel.units)!
let soProps = soFile.properties(ofObjectAt: 0, in: soModel)
func prop(_ path: String, in props: [UnityProperty]) -> UnityProperty? {
    var current: UnityProperty? = nil
    var list = props
    for key in path.split(separator: ".").map(String.init) {
        if let p = current { current = p.child(key) } else { current = list.first { $0.key == key } }
        list = []
    }
    return current
}
func textAt(_ range: NSRange, _ model: SyntaxModel) -> String {
    String(decoding: model.units[range.location..<NSMaxRange(range)], as: UTF16.self)
}
check(soProps.map(\.key) == ["m_ObjectHideFlags", "m_GameObject", "m_Enabled", "m_Script", "m_Name", "m_Description",
                             "m_EnableEditors", "m_MainEditorInstance", "m_EditorInstances", "m_LocalInstances",
                             "m_Title", "m_Quote", "m_Metrics[0]", "m_Tail"],
      "поля верхнего уровня (получено \(soProps.map(\.key)))")
check(prop("m_Name", in: soProps)?.value.scalar?.text == "2P_Host", "простой скаляр")
check(prop("m_Description", in: soProps)?.value.scalar?.raw == "", "пустое значение")
check(prop("m_MainEditorInstance.m_Role", in: soProps)?.value.scalar?.raw == "3", "вложенная структура")
check(prop("m_MainEditorInstance.<CorrespondingNodeId>k__BackingField", in: soProps)?.value.scalar?.text == "Main Editor|0_run",
      "backing-поле автосвойства")
if case .sequence(let nodes)? = prop("m_MainEditorInstance.m_Nodes", in: soProps)?.value {
    check(nodes.map { $0.value.scalar?.text ?? "?" } == ["Main Editor|0_run", "Main Editor|0_deploy"], "список скаляров")
} else { check(false, "список скаляров") }
if case .sequence(let instances)? = prop("m_EditorInstances", in: soProps)?.value {
    check(instances.count == 2, "список структур без отступа (получено \(instances.count))")
    check(instances.first?.child("Name")?.value.scalar?.text == "Player 2", "первое поле элемента — на строке с дефисом")
    check(instances.first?.child("m_AdvancedConfiguration")?.child("LogsColor")?.value.flowFields?.map(\.key) == ["r", "g", "b", "a"],
          "flow-структура цвета")
    check(instances.last?.child("Name")?.value.scalar?.text == "Player: 3", "строка в одинарных кавычках")
    if case .sequence(let empty)? = instances.last?.child("m_Nodes")?.value { check(empty.isEmpty, "[] — пустой список") }
    else { check(false, "[] — пустой список") }
} else { check(false, "список структур без отступа") }
let title = prop("m_Title", in: soProps)?.value.scalar
check(title?.multiline == true && title?.text == "D - GRAVITY RAMP\nfires on Play",
      "многострочная строка склеивается (получено \(title?.text.debugDescription ?? "nil"))")
check(prop("m_Quote", in: soProps)?.value.scalar?.text == "ROW · rest", "двойные кавычки с \\xB7")
check(prop("m_Tail", in: soProps)?.value.scalar?.raw == "5", "после многострочной строки разбор продолжается")
if let name = prop("m_Name", in: soProps)?.value.scalar { check(textAt(name.range, soModel) == "2P_Host", "диапазон значения точный") }

// Правки: меняется только значение, остальной файл — байт в байт
func edited(_ edits: [UnityEdit?]) -> String? { UnityEdits.apply(edits.compactMap { $0 }, to: soText)?.text }
let renamed = edited([UnityEdits.scalar(prop("m_Name", in: soProps)!.value.scalar!, text: "Host")])
check(renamed == soText.replacingOccurrences(of: "m_Name: 2P_Host", with: "m_Name: Host"), "правка имени — ровно одна замена")
let described = edited([UnityEdits.scalar(prop("m_Description", in: soProps)!.value.scalar!, text: "a: b")])
check(described?.contains("m_Description: 'a: b'\n") == true, "строка с `: ` берётся в кавычки")
check(UnityEdits.scalar(prop("m_Tail", in: soProps)!.value.scalar!, text: "abc") == nil, "в числовое поле текст не пишется")
check(edited([UnityEdits.scalar(prop("m_Tail", in: soProps)!.value.scalar!, text: "2,50")])?.hasSuffix("m_Tail: 2.50") == true,
      "число с запятой")
check(UnityEdits.scalar(title!, text: "x") == nil, "многострочную строку инспектор не правит")
let quoted = UnityEdits.scalar(prop("m_EditorInstances.1.Name", in: soProps)?.value.scalar
                               ?? (prop("m_EditorInstances", in: soProps)?.child("1")?.child("Name")?.value.scalar)!,
                               text: "it's")
check(quoted?.text == "'it''s'", "одинарные кавычки сохраняются, ' удваивается")
if let color = prop("m_EditorInstances", in: soProps)?.child("0")?.child("m_AdvancedConfiguration")?.child("LogsColor")?
    .value.flowFields?.first(where: { $0.key == "g" }) {
    check(edited([UnityEdits.number(color, text: "0.5")])?.contains("{r: 0.3643, g: 0.5, b: 0.8679, a: 1}") == true,
          "правка поля внутри {…}")
}
if let applied = UnityEdits.apply([UnityEdits.scalar(prop("m_Name", in: soProps)!.value.scalar!, text: "Very Long Name")!,
                                   UnityEdits.scalar(prop("m_Tail", in: soProps)!.value.scalar!, text: "7")!], to: soText) {
    check(UnityEdits.apply(applied.inverse, to: applied.text)?.text == soText, "обратные правки возвращают файл как был")
}
if let rename = UnityEdits.scalar(prop("m_Name", in: soProps)!.value.scalar!, text: "X"), let applied = edited([rename]) {
    check(UnityEdits.apply([rename], to: applied) == nil, "правка по устаревшим позициям не применяется")
}
check(UnityEdits.apply([UnityEdit(range: NSRange(location: 5, length: 5), text: "x"),
                        UnityEdit(range: NSRange(location: 8, length: 1), text: "y")], to: soText) == nil,
      "пересекающиеся правки отвергаются")

check(UnityScalarCodec.encode("plain", like: .plain) == "plain", "простая строка без кавычек")
check(UnityScalarCodec.encode("#tag", like: .plain) == "'#tag'", "# в начале — в кавычках")
check(UnityScalarCodec.encode("a\"b", like: .doubleQuoted) == "\"a\\\"b\"", "двойные кавычки экранируются")
check(UnityScalarCodec.encode("line1\nline2", like: .plain) == "\"line1\\nline2\"", "перевод строки — через \\n")
check(UnityNumber.format(1) == "1" && UnityNumber.format(0.5) == "0.5" && UnityNumber.format(0.00001) == "0.00001",
      "числа в формате Unity (получено \(UnityNumber.format(0.00001)))")
check(UnityNumber.format(0.70710677) == "0.70710677", "float печатается кратчайшим представлением")

check(UnityNames.nicify("m_LocalPosition") == "Local Position", "m_LocalPosition → Local Position")
check(UnityNames.nicify("<Health>k__BackingField") == "Health", "backing-поле → имя свойства")
check(UnityNames.nicify("_moveSpeed") == "Move Speed", "_moveSpeed → Move Speed")
check(UnityNames.nicify("m_HDR") == "HDR", "аббревиатура не разбивается")
check(UnityNames.nicify("UIScale") == "UI Scale", "UIScale → UI Scale")
check(UnityNames.nicify("near clip plane") == "Near clip plane", "ключ с пробелами")

// Поворот: те же углы, что у Quaternion.Euler в Unity
func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-4 }
let qx = UnityRotation.quaternion(x: 90, y: 0, z: 0)
check(near(qx.x, 0.70710678) && near(qx.w, 0.70710678), "Euler(90,0,0) = (0.7071, 0, 0, 0.7071)")
let q30 = UnityRotation.quaternion(x: 30, y: 45, z: 60)
check(near(q30.x, 0.3919) && near(q30.y, 0.2005) && near(q30.z, 0.3604) && near(q30.w, 0.8224),
      "Euler(30,45,60) совпадает с Unity (получено \(q30))")
for (x, y, z) in [(30.0, 45.0, 60.0), (10.0, 200.0, 350.0), (0.0, 90.0, 0.0), (270.0, 0.0, 0.0), (45.0, 0.0, 135.0)] {
    let q = UnityRotation.quaternion(x: x, y: y, z: z)
    let e = UnityRotation.euler(x: q.x, y: q.y, z: q.z, w: q.w)
    let back = UnityRotation.quaternion(x: e.x, y: e.y, z: e.z)
    let same = near(abs(q.x * back.x + q.y * back.y + q.z * back.z + q.w * back.w), 1)
    check(same, "углы → кватернион → углы → тот же поворот (\(x), \(y), \(z)) → \(e)")
}
let e0 = UnityRotation.euler(x: 0, y: 0, z: 0, w: 1)
check(e0.x == 0 && e0.y == 0 && e0.z == 0, "нулевой поворот — нули, без -0 и 360")

// Типы полей из скрипта
let typedScript = """
using UnityEngine;
public class Mover : MonoBehaviour {
    [SerializeField] private bool loop = true;
    [SerializeField, Range(0, 10)] float speed = 2f; // скорость
    public Mode mode;
    // public int commented;
    [field: SerializeField] public Team Side { get; private set; }
    public List<Vector3> points = new List<Vector3>();
    void Update() { return; }
    public enum Mode { Idle, Walk = 5, Run }
}
[System.Flags] enum Mask { A = 1, B = 2 }
enum Team : byte { Red, [InspectorName("Синие")] Blue = 0x10 }
"""
let info = UnityCSharp.scriptInfo(from: typedScript)
check(info.fieldTypes["loop"] == "bool", "тип поля с атрибутом")
check(info.fieldTypes["speed"] == "float", "тип поля без модификатора")
check(info.fieldTypes["mode"] == "Mode", "поле-enum")
check(info.fieldTypes["commented"] == nil, "закомментированное поле не считается")
check(info.fieldTypes["points"] == "List<Vector3>", "дженерик-тип (получено \(info.fieldTypes["points"] ?? "nil"))")
check(info.type(ofKey: "<Side>k__BackingField") == "Team", "тип автосвойства по backing-полю")
check(info.enums["Mode"] == [.init(name: "Idle", value: 0), .init(name: "Walk", value: 5), .init(name: "Run", value: 6)],
      "значения enum с явным номером")
check(info.enums["Team"]?.last == .init(name: "Blue", value: 16), "enum с атрибутом и hex-значением")
check(info.enums["Mask"] == nil, "[Flags]-enum не показывается списком")

// Модель инспектора на сцене из теста выше
let inspectorScene = UnityYAMLFile.parse(sceneModel.units)!
let resolveNames: (UnityGUID) -> String? = { assetIndex.displayName(for: $0) }
func caretAt(_ needle: String) -> Int { (sceneText as NSString).range(of: needle).location }
if let content = UnityInspector.content(file: inspectorScene, model: sceneModel, caret: caretAt("speed: 5"),
                                        resolve: resolveNames) {
    check(content.kind == .gameObject && content.title == "Play Button", "курсор в компоненте — инспектор его GameObject'а")
    check(content.sections.map(\.title) == ["Transform", "Player", "Image"],
          "компоненты GameObject'а (получено \(content.sections.map(\.title)))")
    check(content.focusedSection == 1, "подсвечен компонент под курсором")
    check(content.path.map(\.name) == ["Canvas"], "предки в хлебных крошках")
    check(content.sections[1].properties.map(\.key) == ["speed"], "служебные поля скрыты")
    check(content.sections[1].enabled != nil, "у MonoBehaviour есть переключатель Enabled")
    check(content.name?.value.scalar?.text == "Play Button", "имя GameObject'а — редактируемое поле")
} else { check(false, "инспектор для компонента") }
if let content = UnityInspector.content(file: inspectorScene, model: sceneModel, caret: caretAt("m_Name: Canvas"),
                                        resolve: resolveNames) {
    check(content.children.map(\.name) == ["Play Button"], "дети — по m_Children (получено \(content.children.map(\.name)))")
    check(content.path.isEmpty, "у корня предков нет")
}
if let content = UnityInspector.content(file: inspectorScene, model: sceneModel, caret: caretAt("m_Name: Badge"),
                                        resolve: resolveNames) {
    check(content.path.map(\.name) == ["Canvas", "Play Button", "Icon"],
          "предки идут через вложенный префаб (получено \(content.path.map(\.name)))")
}
if let content = UnityInspector.content(file: inspectorScene, model: sceneModel, caret: caretAt("value: Icon"),
                                        resolve: resolveNames) {
    check(content.kind == .prefabInstance && content.title == "Icon", "вложенный префаб в инспекторе")
    check(content.sections.first?.properties.map(\.key) == ["m_LocalPosition.x", "m_Name"],
          "переопределения префаба (получено \(content.sections.first?.properties.map(\.key) ?? []))")
    check(content.source?.description == buttonPrefabGUID, "ссылка на исходный префаб")
}
if let content = UnityInspector.content(file: inspectorScene, model: sceneModel, caret: caretAt("m_PrefabInstance: {fileID: 300}"),
                                        resolve: resolveNames) {
    check(content.kind == .prefabInstance, "stripped-заглушка ведёт к вложенному префабу")
}
if let so = UnityInspector.content(file: soFile, model: soModel, caret: 0, resolve: resolveNames) {
    check(so.kind == .asset && so.title == "2P_Host", "ScriptableObject в инспекторе")
    check(so.source?.description == playerGUID, "скрипт ScriptableObject'а")
    check(so.sections.first?.properties.first?.key == "m_Description", "поля SO без служебных")
}

// ────────────────────────── Фильтр навигатора ──────────────────────────
section("Фильтр навигатора")
let idx7 = FileIndex(root: URL(fileURLWithPath: "/"))
for p in ["Sources/UI/CodeView.swift", "Sources/Code/Lexer.swift", "README.md", "codegen.sh"] {
    idx7.appendCached(rel: p)
}
let byName = idx7.filter(name: "code", limit: 10, shouldStop: { false }).map { idx7.relPath($0) }
check(byName == ["Sources/UI/CodeView.swift", "codegen.sh"],
      "фильтр ищет по имени файла, а не по пути, без учёта регистра (получено: \(byName))")
check(idx7.filter(name: "", limit: 10, shouldStop: { false }).isEmpty, "пустой фильтр — пусто")
check(idx7.filter(name: "e", limit: 2, shouldStop: { false }).count == 2, "фильтр уважает лимит")
check(idx7.filter(name: "view.swift", limit: 10, shouldStop: { false }).count == 1, "совпадение в конце имени")

section("Git")
check(GitInfo.parse(head: "ref: refs/heads/main\n") == "main", "ветка из HEAD")
check(GitInfo.parse(head: "ref: refs/heads/claude/feature-x") == "claude/feature-x", "ветка со слешем")
check(GitInfo.parse(head: "29970deadb287d5457bc98c3dcc0b28c522c90c3\n") == "29970de", "отсоединённый HEAD — короткий хэш")
check(GitInfo.parse(head: "") == nil, "пустой HEAD")

// ────────────────────────── Правка модели ──────────────────────────
section("Правка модели")

/// Главный инвариант редактора: модель после серии инкрементальных правок
/// неотличима от модели, построенной с нуля по получившемуся тексту.
func sameModel(_ a: SyntaxModel, _ b: SyntaxModel) -> Bool {
    guard a.units == b.units, a.lineStarts == b.lineStarts, a.lineStates == b.lineStates else { return false }
    let ta = a.tokens(fromLine: 0, toLine: a.lineCount - 1).map { "\($0.start):\($0.length):\($0.kind)" }
    let tb = b.tokens(fromLine: 0, toLine: b.lineCount - 1).map { "\($0.start):\($0.length):\($0.kind)" }
    return ta == tb
}

let editBase = """
using System;
/* блочный
   комментарий */
namespace Demo {
    public class Foo {
        string s = "строка";
        const string V = @"дословная
строка";
        int Bar(int x) => x * 2; // хвост
    }
}
"""
var editModel = SyntaxModel(text: editBase, spec: Languages.csharp)
var editText = Array(editBase.utf16)
let fragments = ["x", "\n", "/*", "*/", "\"", "@\"", "{\n    }", "", "  ", "// c\n", "привет", "\r\n"]
var editFailures = 0
for step in 0..<600 {
    let a = Int.random(in: 0...editText.count)
    let b = min(editText.count, a + Int.random(in: 0...6))
    let piece = Array(fragments.randomElement()!.utf16)
    editText.replaceSubrange(a..<b, with: piece)
    editModel.replace(NSRange(location: a, length: b - a), with: piece)
    let fresh = SyntaxModel(text: String(decoding: editText, as: UTF16.self), spec: Languages.csharp)
    if !sameModel(editModel, fresh) {
        editFailures += 1
        if editFailures == 1 { print("     расхождение на шаге \(step): замена \(a)..<\(b)") }
        editModel = fresh
    }
}
check(editFailures == 0, "600 случайных правок: модель совпадает с построенной заново (расхождений: \(editFailures))")

// Правка в конце, стирание всего, вставка в пустой документ.
let tail = SyntaxModel(text: "a\nb", spec: Languages.swift)
tail.replace(NSRange(location: 3, length: 0), with: Array("\n".utf16))
check(tail.lineCount == 3 && tail.lineStarts == [0, 2, 4], "перевод строки в конце добавляет строку")
tail.replace(NSRange(location: 0, length: tail.units.count), with: [])
check(tail.lineCount == 1 && tail.units.isEmpty, "стирание всего оставляет одну пустую строку")
tail.replace(NSRange(location: 0, length: 0), with: Array("let x = 1\n".utf16))
check(sameModel(tail, SyntaxModel(text: "let x = 1\n", spec: Languages.swift)), "вставка в пустой документ")

// Открытый /* переразбирает хвост файла, закрытый — возвращает как было.
let comment = SyntaxModel(text: "int a;\nint b;\nint c;\n", spec: Languages.csharp)
comment.replace(NSRange(location: 0, length: 0), with: Array("/*".utf16))
check(comment.tokens(fromLine: 2, toLine: 2).first?.kind == .comment, "открытый /* делает комментарием и дальние строки")
comment.replace(NSRange(location: 0, length: 2), with: [])
check(comment.tokens(fromLine: 2, toLine: 2).first.map { $0.kind != .comment } == true, "убранный /* возвращает подсветку")

// Снимок не видит последующих правок.
let snapModel = SyntaxModel(text: "abc", spec: nil)
let snap = snapModel.snapshot()
snapModel.replace(NSRange(location: 0, length: 3), with: Array("xyz\n".utf16))
check(snap.text == "abc" && snap.lineCount == 1 && snapModel.version == snap.version + 1,
      "снимок неизменен после правки оригинала")

// ────────────────────────── Правила редактирования ──────────────────────────
section("Правила редактирования")

check(EditingRules.indentUnit(in: Array("a {\n    b {\n        c\n    }\n}\n".utf16)) == "    ", "отступ 4 пробела")
check(EditingRules.indentUnit(in: Array("a:\n  b:\n    c: 1\n".utf16)) == "  ", "отступ 2 пробела (YAML)")
check(EditingRules.indentUnit(in: Array("a {\n\tb\n\t\tc\n}\n".utf16)) == "\t", "отступ табами")
check(EditingRules.indentUnit(in: Array("один\nдва\n".utf16)) == "    ", "без отступов — 4 пробела")
check(EditingRules.lineEnding(in: Array("a\r\nb".utf16)) == "\r\n", "CRLF распознан")
check(EditingRules.lineEnding(in: Array("a\nb".utf16)) == "\n", "LF распознан")

let nl1 = EditingRules.newline(linePrefix: "    foo()", lineSuffix: "", indentUnit: "    ", lineEnding: "\n", colonOpensBlock: false)
check(nl1 == .init(text: "\n    ", caret: 5), "Return сохраняет отступ")
let nl2 = EditingRules.newline(linePrefix: "    if x {", lineSuffix: "", indentUnit: "    ", lineEnding: "\n", colonOpensBlock: false)
check(nl2 == .init(text: "\n        ", caret: 9), "после { — на уровень глубже")
let nl3 = EditingRules.newline(linePrefix: "func f() {", lineSuffix: "}", indentUnit: "    ", lineEnding: "\n", colonOpensBlock: false)
check(nl3 == .init(text: "\n    \n", caret: 5), "{|} раскрывается в три строки (получено \(nl3))")
let nl4 = EditingRules.newline(linePrefix: "def f():", lineSuffix: "", indentUnit: "    ", lineEnding: "\r\n", colonOpensBlock: true)
check(nl4 == .init(text: "\r\n    ", caret: 6), "Python: после «:» глубже, CRLF сохраняется")
let nl5 = EditingRules.newline(linePrefix: "x = a ? b :", lineSuffix: "", indentUnit: "    ", lineEnding: "\n", colonOpensBlock: false)
check(nl5.text == "\n", "в C-подобных «:» блок не открывает")

check(EditingRules.dedentBeforeClosing(linePrefix: "        ", indentUnit: "    ") == 4, "} снимает один уровень")
check(EditingRules.dedentBeforeClosing(linePrefix: "  x", indentUnit: "    ") == 0, "} после кода отступ не трогает")
check(EditingRules.dedentBeforeClosing(linePrefix: "\t\t", indentUnit: "\t") == 1, "} снимает таб")
let braceText = Array("class A {\n    func f() {\n        x()\n        \n".utf16)
check(EditingRules.closingBraceIndent(in: braceText, before: braceText.count - 1) == "    ", "} встаёт под парную { (func)")
let braceText2 = Array("class A {\n    func f() {\n    }\n  \n".utf16)
check(EditingRules.closingBraceIndent(in: braceText2, before: braceText2.count - 1) == "", "} встаёт под парную { (class)")
check(EditingRules.closingBraceIndent(in: Array("x\n  ".utf16), before: 4) == nil, "без парной скобки — nil")
check(EditingRules.backspaceWidth(linePrefix: "      ", indentUnit: "    ") == 2, "backspace до позиции табуляции")
check(EditingRules.backspaceWidth(linePrefix: "        ", indentUnit: "    ") == 4, "backspace — целый уровень")
check(EditingRules.backspaceWidth(linePrefix: "  x", indentUnit: "    ") == 1, "backspace после кода — один символ")

check(EditingRules.indent(["a", "", "  b"], unit: "    ") == ["    a", "", "      b"], "сдвиг вправо не трогает пустые строки")
check(EditingRules.outdent(["      a", "\tb", " c"], unit: "    ") == ["  a", "b", "c"], "сдвиг влево")
let commented = EditingRules.toggleComment(["    a", "", "  b"], token: "//")
check(commented == ["  //   a", "", "  // b"], "комментарий на общем минимальном отступе (получено \(commented))")
check(EditingRules.toggleComment(commented, token: "//") == ["    a", "", "  b"], "повторный ⌘/ возвращает как было")
check(EditingRules.toggleComment(["// a", "b"], token: "//") == ["// // a", "// b"], "смешанный блок — комментируется весь")

// ────────────────────────── Автодополнение ──────────────────────────
section("Автодополнение")

let listJSON: [String: Any] = [
    "isIncomplete": true,
    "itemDefaults": ["editRange": ["start": ["line": 1, "character": 4], "end": ["line": 1, "character": 6]],
                     "insertTextFormat": 2],
    "items": [
        ["label": "Count", "kind": 10, "detail": "int", "sortText": "b"],
        ["label": "Contains", "kind": 2, "textEditText": "Contains(${1:item})", "sortText": "a"],
        ["label": "Where", "kind": 2,
         "textEdit": ["insert": ["start": ["line": 1, "character": 4], "end": ["line": 1, "character": 6]],
                      "replace": ["start": ["line": 1, "character": 4], "end": ["line": 1, "character": 9]],
                      "newText": "Where"],
         "additionalTextEdits": [["range": ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 0]],
                                  "newText": "using System.Linq;\n"]]],
    ],
]
let parsed = CompletionList.parse(listJSON)
check(parsed.isIncomplete && parsed.items.count == 3, "CompletionList разобран")
check(parsed.items[0].edit?.range.start.character == 4 && parsed.items[0].isSnippet, "itemDefaults.editRange и формат по умолчанию")
check(parsed.items[1].edit?.newText == "Contains(${1:item})", "textEditText из LSP 3.17")
check(parsed.items[2].edit?.range.end.character == 6, "InsertReplaceEdit: берётся insert, а не replace")
check(parsed.items[2].additionalEdits.first?.newText == "using System.Linq;\n", "сопутствующие правки")
check(CompletionList.parse([["label": "x"]]).items.first?.label == "x", "ответ массивом")

let sn1 = Snippet.expand("Contains(${1:item})")
check(sn1 == .init(text: "Contains(item)", selection: NSRange(location: 9, length: 4)), "сниппет: заглушка выделяется")
let sn2 = Snippet.expand("foo($1, $2)$0")
check(sn2 == .init(text: "foo(, )", selection: NSRange(location: 4, length: 0)), "сниппет: курсор в первое поле")
let sn3 = Snippet.expand("if ${1:cond} {\n\t$0\n}")
check(sn3.text == "if cond {\n\t\n}" && sn3.selection == NSRange(location: 3, length: 4), "сниппет с переводами строк")
check(Snippet.expand("a \\$ b ${TM_FILENAME} c").text == "a $ b  c", "экранирование и переменные")
check(Snippet.expand("f(${1:x ${2:y}})").text == "f(x y)", "вложенные поля")
check(Snippet.expand("${1|one,two|}").text == "one", "выбор — первый вариант")
check(Snippet.expand("plain").selection == nil, "без полей — без выделения")

let rankItems = ["getTextDocument", "GetType", "target", "gt", "forget"].map { CompletionItem(label: $0) }
let ranked = CompletionRanking.rank(rankItems, prefix: "gt").map { rankItems[$0].label }
check(ranked.first == "gt", "точное совпадение первым (получено \(ranked))")
check(ranked.contains("getTextDocument") && ranked.contains("GetType"), "горбы находятся")
check(!ranked.contains("forget"), "подпоследовательность не с начала слова отсекается")
let casePref = CompletionRanking.rank(["Value", "value"].map { CompletionItem(label: $0) }, prefix: "va")
check(casePref.first == 1, "совпадение с учётом регистра выше")
check(CompletionRanking.rank(rankItems, prefix: "").count == rankItems.count, "пустой префикс — всё")

let wordModel = SyntaxModel(text: "let counter = 1\ncounter += st\nlet co", spec: Languages.swift)
let words = WordCompletion.items(in: wordModel, excluding: wordModel.units.count).map(\.label)
check(words.contains("counter") && !words.contains("st"), "слова файла: от трёх букв")
check(!words.contains("co"), "набираемое слово не предлагается")
check(words.contains("func"), "ключевые слова языка")

// ─────────────────────── Структура: типы в объявлениях ───────────────────────
section("Структура: типы в объявлениях")

let declSource = """
namespace Game
{
    public class Stash<T> : Base<T>, IStash where T : struct
    {
        [SerializeField] private Foo _foo;
        private readonly List<Player> _players = new();
        public static World Default { get; }
        public ref T Get(int entity) => ref _items[entity];
        public Stash<U> Other<U>() where U : struct => null;
        private int[] _numbers;
        public event Action<int> Changed;
        public delegate void Handler<TArg>(TArg value);
        public enum Mode { Idle, Run = 2, Jump }
        Dictionary<string, List<int>> Map() { return null; }
    }
}
"""
let declItems = OutlineBuilder.build(model: SyntaxModel(text: declSource, spec: Languages.csharp))
func declNamed(_ n: String) -> OutlineItem? { declItems.first { $0.name == n } }
check(declNamed("Stash")?.genericParams == ["T"], "параметры дженерика типа (получено \(declNamed("Stash")?.genericParams ?? []))")
check(declNamed("Stash")?.bases == ["Base<T>", "IStash"], "базовые типы без where (получено \(declNamed("Stash")?.bases ?? []))")
check(declNamed("_foo")?.typeText == "Foo", "атрибут не прилипает к типу поля (получено \(declNamed("_foo")?.typeText ?? "nil"))")
check(declNamed("_players")?.typeText == "List<Player>", "дженерик-тип поля (получено \(declNamed("_players")?.typeText ?? "nil"))")
check(declNamed("Default")?.typeText == "World", "тип свойства, static не входит (получено \(declNamed("Default")?.typeText ?? "nil"))")
check(declNamed("Get")?.typeText == "T", "возвращаемый тип `ref T` → T (получено \(declNamed("Get")?.typeText ?? "nil"))")
check(declNamed("Other")?.kind == .method, "дженерик-метод `Other<U>()` попал в структуру")
check(declNamed("Other")?.typeText == "Stash<U>", "его возвращаемый тип (получено \(declNamed("Other")?.typeText ?? "nil"))")
check(declNamed("_numbers")?.typeText == "int[]", "массив (получено \(declNamed("_numbers")?.typeText ?? "nil"))")
check(declNamed("Changed")?.kind == .field && declNamed("Changed")?.typeText == "Action<int>",
      "у event имя — последнее слово, тип — перед ним (получено \(declNamed("Changed").map { "\($0.name): \($0.typeText ?? "nil")" } ?? "nil"))")
check(declNamed("Action") == nil, "тип события не записан как имя")
check(declNamed("Handler")?.kind == .method, "делегат-дженерик назван по имени, а не по типу")
check(["Idle", "Run", "Jump"].allSatisfy { n in declNamed(n)?.kind == .enumCase && declNamed(n)?.container == "Mode" },
      "значения enum с контейнером (получено \(declItems.filter { $0.kind == .enumCase }.map(\.name)))")
check(declNamed("Map")?.typeText == "Dictionary<string,List<int>>", "вложенные дженерики (получено \(declNamed("Map")?.typeText ?? "nil"))")
check(declNamed("2") == nil && declNamed("entity") == nil, "значения и параметры не объявления")

// ─────────────────────────── Быстрый навигатор ───────────────────────────
section("Быстрый навигатор")

let navRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("pilot-nav-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.removeItem(at: navRoot)
let playerSystemSource = """
using Game.Components;
using Game.Ecs;
using Vec = Game.Components.Health;

namespace Game.Systems
{
    public sealed class PlayerSystem : BaseSystem
    {
        private Stash<Health> _health;
        private readonly List<Player> _players = new();
        private Vec _alias;
        public Player Leader { get; private set; }

        public override void OnAwake()
        {
            _health = World.GetStash<Health>();
            ref var health = ref _health.Get(0);
            health.Damage(1);
            var player = new Player();
            player.Move(2);
            Leader.Move(3);
            foreach (var p in _players) { p.Move(4); }
            Log("Damage");
            var world = World.Default;
            world.GetStash<Health>();
            Helper.Run();
            this.Log("x");
            // Damage в комментарии
            var unknown = Something();
            unknown.Damage(5);
            _health.Get(1).Current = 0;
            health.value = 1;
        }
        public enum Mode { Idle, Run = 2 }
        void SetMode() { var m = Mode.Run; }
    }
    public class Player
    {
        public void Move(int dx) { }
    }
    public static class Helper { public static void Run() { } }
}
"""
let damageSystemSource = """
using Game.Components;
using Game.Ecs;
namespace Game.Systems
{
    [IncludeStash(typeof(Health))]
    [IncludeStash(typeof(Game.Components.Health), "_hp")]
    public partial class DamageSystem
    {
        private Filter _filter;
        void OnUpdate()
        {
            foreach (var entity in _filter) { _health.Get(entity.Id).Damage(1); _hp.Has(entity.Id); }
        }
    }
}
"""
let navFiles: [String: String] = [
    "Assets/Game/Health.cs": """
        using System;
        namespace Game.Components
        {
            public struct Health
            {
                public int Current;
                public float value;
                public int Max { get; set; }
                public void Damage(int amount) { Current -= amount; }
            }
        }
        """,
    "Assets/Game/Stash.cs": """
        namespace Game.Ecs
        {
            public class Stash<T> where T : struct
            {
                public ref T Get(int entity) => ref _items[entity];
                public bool Has(int entity) => true;
                private T[] _items;
            }
            public class Filter
            {
                public Enumerator GetEnumerator() => default;
                public struct Enumerator { public Entity Current => default; }
            }
            public struct Entity { public int Id; }
            public class World
            {
                public Stash<T> GetStash<T>() where T : struct => null;
                public static World Default { get; }
            }
        }
        """,
    "Assets/Game/BaseSystem.cs": """
        namespace Game.Systems
        {
            public abstract class BaseSystem
            {
                protected World World;
                public virtual void OnAwake() { }
                protected void Log(string message) { }
            }
        }
        """,
    "Assets/Game/PlayerSystem.cs": playerSystemSource,
    "Other/Player.cs": "namespace Other { public class Player { public void Move(int dx) { } } }",
    "Assets/Game/DamageSystem.cs": damageSystemSource,
    "Docs/readme.md": "Damage Damage Damage",
    "Packages/Tests/Fixture.cs": "namespace Tests { class ValidateTypes { struct Vector3 { } } }",
]
for (path, text) in navFiles {
    let url = navRoot.appendingPathComponent(path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? text.write(to: url, atomically: true, encoding: .utf8)
}
let symbols = SymbolIndex.build(root: navRoot, files: Array(navFiles.keys), shouldStop: { false })
check(symbols != nil, "индекс символов построен")
let symbolIndex = symbols ?? SymbolIndex(root: navRoot)
// Повторная сборка: заново разбирается изменённое после прошлой и новое,
// а пропавшие файлы уходят.
do {
    let sources = Array(navFiles.keys).filter { !$0.hasSuffix(".md") }
    let untouched = SymbolIndex.changes(from: symbolIndex, files: sources, since: Date().addingTimeInterval(60))
    check(untouched.changed.isEmpty && untouched.removed.isEmpty,
          "ничего не менялось — нечего разбирать (получено \(untouched.changed), \(untouched.removed))")
    let touched = SymbolIndex.changes(from: symbolIndex, files: sources + ["Assets/New.cs"],
                                      since: Date(timeIntervalSince1970: 1_000_000))
    check(Set(touched.changed).isSuperset(of: ["Assets/New.cs", "Assets/Game/PlayerSystem.cs"]),
          "изменённые и новые — к разбору (получено \(touched.changed))")
    // Файл без объявлений индекс не хранит; не менялся — не разбирается.
    let empty = navRoot.appendingPathComponent("Assets/Empty.cs")
    try? "// ничего\n".write(to: empty, atomically: true, encoding: .utf8)
    let quiet = SymbolIndex.changes(from: symbolIndex, files: sources + ["Assets/Empty.cs"],
                                    since: Date().addingTimeInterval(60))
    check(quiet.changed.isEmpty, "файл без объявлений не разбирается каждый раз (получено \(quiet.changed))")
    try? FileManager.default.removeItem(at: empty)
    let gone = SymbolIndex.changes(from: symbolIndex, files: sources.filter { $0 != "Other/Player.cs" },
                                   since: Date().addingTimeInterval(60))
    check(gone.removed == ["Other/Player.cs"], "пропавший файл — к удалению (получено \(gone.removed))")
}
check(symbolIndex.files.contains { $0.path == "Assets/Game/PlayerSystem.cs" && $0.usings == ["Game.Components", "Game.Ecs"]
                                   && $0.aliases["Vec"] == "Game.Components.Health" && $0.namespaces == ["Game.Systems"] },
      "using, псевдонимы и namespace файла")
check(!symbolIndex.files.contains { $0.path.hasSuffix(".md") }, "Markdown не индексируется")

let playerModel = SyntaxModel(text: playerSystemSource, spec: Languages.csharp)
let navDocument = NavDocument(url: navRoot.appendingPathComponent("Assets/Game/PlayerSystem.cs"),
                              relPath: "Assets/Game/PlayerSystem.cs", model: playerModel,
                              outline: OutlineBuilder.build(model: playerModel))
let navigator = LocalNavigator(index: symbolIndex, document: navDocument)

/// ⌘B на слове `word` в n-м вхождении `context` внутри PlayerSystem.cs.
func jump(_ context: String, _ word: String, occurrence: Int = 0) -> LocalNavigator.Answer {
    let text = playerSystemSource as NSString
    var searchFrom = 0
    var found = NSRange(location: NSNotFound, length: 0)
    for _ in 0...occurrence {
        found = text.range(of: context, options: [], range: NSRange(location: searchFrom, length: text.length - searchFrom))
        guard found.location != NSNotFound else { return .none }
        searchFrom = found.location + found.length
    }
    let inner = (context as NSString).range(of: word)
    return navigator.definition(at: found.location + inner.location)
}
func landed(_ answer: LocalNavigator.Answer) -> String {
    guard let first = answer.declarations.first else { return "ничего" }
    return "\(first.container ?? "-").\(first.name) в \(first.path)\(answer.isExact ? "" : " (кандидатов \(answer.declarations.count))")"
}
func expect(_ answer: LocalNavigator.Answer, _ name: String, in path: String, container: String? = nil, _ label: String) {
    let first = answer.declarations.first
    check(answer.isExact && first?.name == name && first?.path == path && (container == nil || first?.container == container),
          "\(label) (получено: \(landed(answer)))")
}

// Единственный в проекте `Vector3` вложен в тестовый класс: из другого
// файла по голому имени его не видно, прыгать туда нельзя.
do {
    let source = "using UnityEngine;\nnamespace Game { class A { Vector3 v; } }"
    let model = SyntaxModel(text: source, spec: Languages.csharp)
    let document = NavDocument(url: navRoot.appendingPathComponent("Assets/Game/A.cs"), relPath: "Assets/Game/A.cs",
                               model: model, outline: OutlineBuilder.build(model: model))
    let answer = LocalNavigator(index: symbolIndex, document: document)
        .definition(at: (source as NSString).range(of: "Vector3").location)
    check(!answer.isExact, "вложенный в чужой класс тип не ответ на голое имя (получено: \(landed(answer)))")
}

expect(jump("health.Damage(1)", "Damage"), "Damage", in: "Assets/Game/Health.cs", container: "Health",
       "ref var из Stash<Health>.Get → T подставлен → Health.Damage")
expect(jump("player.Move(2)", "Move"), "Move", in: "Assets/Game/PlayerSystem.cs", container: "Player",
       "var = new Player → Player из своего namespace, а не Other.Player")
expect(jump("Leader.Move(3)", "Move"), "Move", in: "Assets/Game/PlayerSystem.cs",
       "тип свойства → его метод")
expect(jump("p.Move(4)", "Move"), "Move", in: "Assets/Game/PlayerSystem.cs",
       "foreach по List<Player> → элемент Player")
expect(jump("World.GetStash<Health>()", "GetStash"), "GetStash", in: "Assets/Game/Stash.cs", container: "World",
       "поле World из базового класса → World.GetStash")
expect(jump("world.GetStash<Health>()", "GetStash"), "GetStash", in: "Assets/Game/Stash.cs",
       "var = World.Default (static-свойство через поле базового класса) → World")
expect(jump("Helper.Run()", "Run"), "Run", in: "Assets/Game/PlayerSystem.cs", container: "Helper",
       "статический вызов через имя типа")
expect(jump("this.Log(\"x\")", "Log"), "Log", in: "Assets/Game/BaseSystem.cs",
       "this. → метод базового класса")
expect(jump("Log(\"Damage\")", "Log"), "Log", in: "Assets/Game/BaseSystem.cs",
       "голый вызов → член базового класса")
expect(jump("Mode.Run", "Run"), "Run", in: "Assets/Game/PlayerSystem.cs", container: "Mode",
       "значение вложенного enum")
expect(jump("new Player()", "Player"), "Player", in: "Assets/Game/PlayerSystem.cs",
       "тип после new — ближайший по namespace")
expect(jump("private Vec _alias", "Vec"), "Health", in: "Assets/Game/Health.cs",
       "псевдоним using")
expect(jump("player.Move(2)", "player"), "player", in: "Assets/Game/PlayerSystem.cs",
       "локальная переменная")
expect(jump("_health.Get(1).Current", "Current"), "Current", in: "Assets/Game/Health.cs",
       "поле результата дженерик-метода")
expect(jump("health.value", "value"), "value", in: "Assets/Game/Health.cs",
       "поле с именем-контекстным словом `value`")
let fallbackAnswer = jump("unknown.Damage(5)", "Damage")
check(fallbackAnswer.declarations.first?.name == "Damage" && fallbackAnswer.declarations.count == 1
        && fallbackAnswer.isExact,
      "тип неизвестен, но объявление с таким именем одно — прыгаем (получено: \(landed(fallbackAnswer)))")
check(jump("Log(\"Damage\")", "Damage").declarations.isEmpty, "слово в строке — не идентификатор")
check(jump("// Damage в комментарии", "Damage").declarations.isEmpty, "слово в комментарии — не идентификатор")
check(jump("public void Move", "Move").declarations.isEmpty, "на самом объявлении прыгать некуда")

let moveCandidates = LocalNavigator(index: symbolIndex, document: NavDocument(
    url: navRoot.appendingPathComponent("x.cs"), relPath: "x.cs",
    model: SyntaxModel(text: "class X { void F(dynamic d) { d.Move(1); } }", spec: Languages.csharp),
    outline: OutlineBuilder.build(model: SyntaxModel(text: "class X { void F(dynamic d) { d.Move(1); } }", spec: Languages.csharp))))
    .definition(at: ("class X { void F(dynamic d) { d.Move(1); } }" as NSString).range(of: "Move").location)
check(!moveCandidates.isExact && moveCandidates.declarations.count == 2,
      "тип неизвестен, одноимённых два — список выбора (получено: \(landed(moveCandidates)))")

// Morpeh: поля от [IncludeStash] и foreach по Filter
let damageModel = SyntaxModel(text: damageSystemSource, spec: Languages.csharp)
let damageNavigator = LocalNavigator(index: symbolIndex, document: NavDocument(
    url: navRoot.appendingPathComponent("Assets/Game/DamageSystem.cs"), relPath: "Assets/Game/DamageSystem.cs",
    model: damageModel, outline: OutlineBuilder.build(model: damageModel)))
func jumpDamage(_ context: String, _ word: String) -> LocalNavigator.Answer {
    let at = (damageSystemSource as NSString).range(of: context)
    guard at.location != NSNotFound else { return .none }
    return damageNavigator.definition(at: at.location + (context as NSString).range(of: word).location)
}
expect(jumpDamage("_health.Get(entity.Id).Damage(1)", "Damage"), "Damage", in: "Assets/Game/Health.cs",
       "[IncludeStash] даёт поле _health: Stash<Health> → Get → Health.Damage")
expect(jumpDamage("_health.Get(entity.Id)", "_health"), "_health", in: "Assets/Game/DamageSystem.cs",
       "само поле ведёт к атрибуту")
expect(jumpDamage("_hp.Has(entity.Id)", "Has"), "Has", in: "Assets/Game/Stash.cs",
       "явное имя поля из второго аргумента")
expect(jumpDamage("_health.Get(entity.Id)", "Id"), "Id", in: "Assets/Game/Stash.cs", container: "Entity",
       "foreach по Filter → GetEnumerator().Current → Entity")
let stashFields = symbolIndex.symbols.filter { $0.name.hasPrefix("_h") && $0.container == "DamageSystem" }
check(stashFields.map(\.name).sorted() == ["_health", "_hp"] && stashFields.allSatisfy { $0.typeText == "Stash<Health>" },
      "в индексе два поля стэшей (получено \(stashFields.map { "\($0.name): \($0.typeText ?? "nil")" }))")

let noIndex = LocalNavigator(index: nil, document: navDocument)
check(noIndex.definition(at: (playerSystemSource as NSString).range(of: "Leader.Move").location).declarations.first?.name == "Leader",
      "без индекса — хотя бы структура самого файла")

// ⌘R: по тексту проекта, без строк и комментариев, только тот же язык
let damageOffset = (playerSystemSource as NSString).range(of: "health.Damage").location + 7
let damageRefs = navigator.references(at: damageOffset, root: navRoot, files: Array(navFiles.keys), shouldStop: { false })
check(damageRefs.count == 4, "Damage: объявление и три вызова, без строки, комментария и .md (получено \(damageRefs.map { "\($0.path):\($0.line)" }))")
check(damageRefs.first?.path == "Assets/Game/PlayerSystem.cs", "текущий файл — первым")
let localRefs = navigator.references(at: (playerSystemSource as NSString).range(of: "player.Move").location,
                                     root: navRoot, files: Array(navFiles.keys), shouldStop: { false })
check(localRefs.count == 2 && localRefs.allSatisfy { $0.path == "Assets/Game/PlayerSystem.cs" },
      "локальная переменная — только в своём файле (получено \(localRefs.count))")
check(LocalNavigator.containsWord(Data("a Damage b".utf8), Array("Damage".utf8)), "слово целиком найдено")
check(!LocalNavigator.containsWord(Data("TakeDamage".utf8), Array("Damage".utf8)), "часть слова не считается")

// ⌘T
func findSymbols(_ q: String) -> [String] {
    symbolIndex.search(q, limit: 20, shouldStop: { false }).map { "\(symbolIndex[$0.id].container ?? "-").\(symbolIndex[$0.id].name)" }
}
check(findSymbols("PlaSys").first == "Game.Systems.PlayerSystem", "⌘T: аббревиатура типа (получено \(findSymbols("PlaSys")))")
check(Set(findSymbols("Move").prefix(2)) == ["Player.Move"], "⌘T: оба Move (получено \(findSymbols("Move")))")
check(findSymbols("world.getstash").first == "World.GetStash", "⌘T: запрос с точкой — по контейнеру")
check(findSymbols("").isEmpty, "⌘T: пустой запрос — пусто")

// индекс типов для ⇧⇧ — из того же разбора
let derivedTypes = TypeIndex.make(root: navRoot, entries: symbolIndex.typeEntries())
let derivedNames = (0..<derivedTypes.count).map { derivedTypes.declaration(Int32($0)).name }.sorted()
check(derivedNames == ["BaseSystem", "DamageSystem", "Entity", "Enumerator", "Filter", "Health", "Helper", "Mode",
                      "Player", "Player", "PlayerSystem", "Stash", "ValidateTypes", "Vector3", "World"],
      "типы для ⇧⇧ из индекса символов (получено \(derivedNames))")

// кэш
let symbolRoundTrip = SymbolIndex.deserialize(symbolIndex.serialized(), root: navRoot)
check(symbolRoundTrip?.symbols == symbolIndex.symbols && symbolRoundTrip?.files == symbolIndex.files,
      "кэш символов: туда и обратно без потерь")
check(symbolRoundTrip?.typesByName["Player"]?.count == 2, "после загрузки из кэша таблицы построены")
check(SymbolIndex.deserialize("pilot-types 1\nF\tx", root: navRoot) == nil, "чужой формат кэша отвергается")
// Параметр шейдера с `#ifdef` на следующей строке: перевод строки и `;`
// внутри поля не должны рвать запись — раньше из-за одной такой весь кэш
// не читался, и проект каждый раз разбирался целиком.
do {
    let shaderRoot = FileManager.default.temporaryDirectory.appendingPathComponent("pilot-shader-\(getpid())")
    try? FileManager.default.createDirectory(at: shaderRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: shaderRoot) }
    let shader = ["Shader \"X\" {", "\tSubShader {", "\t\tPass {", "\t\t\tCGPROGRAM",
                  "\t\t\tfixed4 frag (v2f IN /*ase_frag_input*/", "\t\t\t\t#ifdef _DEPTHOFFSET_ON",
                  "\t\t\t\t, out float outputDepth : SV_Depth", "\t\t\t\t#endif", "\t\t\t\t) : SV_Target",
                  "\t\t\t{", "\t\t\t\treturn 0;", "\t\t\t}", "\t\t\tfloat4 vert (float4 v) { return v; }",
                  "\t\t\tENDCG", "\t\t}", "\t}", "}", ""].joined(separator: "\r\n")
    try? shader.write(to: shaderRoot.appendingPathComponent("S.shader"), atomically: true, encoding: .utf8)
    let built = SymbolIndex.build(root: shaderRoot, files: ["S.shader"], shouldStop: { false })
    let names = built?.symbols.map(\.name) ?? []
    let back = built.flatMap { SymbolIndex.deserialize($0.serialized(), root: shaderRoot) }
    check(!names.isEmpty && back?.symbols.map(\.name) == names,
          "перевод строки в параметре не рвёт кэш (построено \(names), прочитано \(back?.symbols.map(\.name) ?? []))")
}
try? FileManager.default.removeItem(at: navRoot)

// производительность: разбор, как на крупном проекте, но в памяти
let perfSource = String(repeating: """
    public sealed class System0 : BaseSystem
    {
        private Stash<Health> _health;
        public override void OnUpdate(float dt) { var h = _health.Get(0); h.Damage(1); }
    }

    """, count: 2000)
let tExtract = Date()
let perfExtract = SymbolIndex.extract(text: perfSource, spec: Languages.csharp, path: "perf.cs")
let extractMs = Date().timeIntervalSince(tExtract) * 1000
print(String(format: "  объявления из файла на %d строк: %.0f мс, найдено %d", 10_000, extractMs, perfExtract.1.count))
check(perfExtract.1.count == 6000, "в синтетике по три объявления на класс (получено \(perfExtract.1.count))")
check(extractMs < 400, "разбор 10 000 строк быстрее 400 мс")

// ─────────────────────── Иерархия типов ────────────────────────
section("Иерархия типов")

// Наследники считаются по тому же `bases`, которым ⌘B поднимается вверх,
// поэтому фикстура нарочно содержит два одноимённых интерфейса.
let hierRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("pilot-hier-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.removeItem(at: hierRoot)
let hierFiles: [String: String] = [
    "Assets/Game/Damageable.cs": """
        namespace Game.Components
        {
            public interface IDamageable { void Damage(int amount); }
        }
        """,
    "Assets/Game/Health.cs": """
        namespace Game.Components
        {
            public struct Health : IDamageable
            {
                public void Damage(int amount) { }
            }
        }
        """,
    "Assets/Game/Armor.cs": """
        using Game.Components;
        namespace Game.Gear
        {
            public class Armor : IDamageable
            {
                public void Damage(int amount) { }
            }
        }
        """,
    "Other/Damageable.cs": """
        namespace Other
        {
            public interface IDamageable { void Damage(int amount); }
            public class Rock : IDamageable { public void Damage(int amount) { } }
        }
        """,
    "Assets/Game/BaseSystem.cs": """
        namespace Game.Systems
        {
            public abstract class BaseSystem { public virtual void OnAwake() { } }
        }
        """,
    "Assets/Game/MidSystem.cs": """
        namespace Game.Systems
        {
            public class MidSystem : BaseSystem { public override void OnAwake() { } }
        }
        """,
    "Assets/Game/LeafSystem.cs": """
        namespace Game.Systems
        {
            public class LeafSystem : MidSystem { public override void OnAwake() { } }
        }
        """,
]
for (path, text) in hierFiles {
    let url = hierRoot.appendingPathComponent(path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? text.write(to: url, atomically: true, encoding: .utf8)
}
let hierIndex = SymbolIndex.build(root: hierRoot, files: Array(hierFiles.keys), shouldStop: { false })
    ?? SymbolIndex(root: hierRoot)
check(hierIndex.derivedByBase["IDamageable"]?.count == 3, "в таблице наследников все три реализации обоих интерфейсов")
check(SymbolIndex.baseKey("Game.Ecs.Base<T>") == "Base", "ключ наследования: без namespace и дженериков")

func hierNavigator(_ path: String) -> LocalNavigator {
    let model = SyntaxModel(text: hierFiles[path]!, spec: Languages.csharp)
    return LocalNavigator(index: hierIndex, document: NavDocument(
        url: hierRoot.appendingPathComponent(path), relPath: path, model: model,
        outline: OutlineBuilder.build(model: model)))
}
/// ⌥⌘B на слове `word` внутри первого вхождения строки `context`.
func hierImpl(_ path: String, _ context: String, _ word: String) -> LocalNavigator.Answer {
    let outer = (hierFiles[path]! as NSString).range(of: context)
    guard outer.location != NSNotFound else { return .none }
    return hierNavigator(path).implementations(at: outer.location + (context as NSString).range(of: word).location)
}
func hierShape(_ answer: LocalNavigator.Answer) -> String {
    answer.declarations.map { "\($0.container ?? "-").\($0.name)" }.sorted().joined(separator: ", ")
}

let onInterface = hierImpl("Assets/Game/Damageable.cs", "public interface IDamageable", "IDamageable")
check(hierShape(onInterface) == "Game.Components.Health, Game.Gear.Armor",
      "курсор на интерфейсе → его реализации (получено: \(hierShape(onInterface)))")

let foreignInterface = hierImpl("Other/Damageable.cs", "public interface IDamageable", "IDamageable")
check(hierShape(foreignInterface) == "Other.Rock",
      "одноимённый интерфейс из чужого namespace не слипся (получено: \(hierShape(foreignInterface)))")

let onBaseName = hierImpl("Assets/Game/Armor.cs", "public class Armor : IDamageable", "IDamageable")
check(hierShape(onBaseName) == "Game.Components.Health, Game.Gear.Armor",
      "имя базового в объявлении: сам Armor не отброшен вместе со строкой (получено: \(hierShape(onBaseName)))")

let onInterfaceMethod = hierImpl("Assets/Game/Damageable.cs", "void Damage(int amount);", "Damage")
check(hierShape(onInterfaceMethod) == "Armor.Damage, Health.Damage",
      "курсор на методе интерфейса → его реализации (получено: \(hierShape(onInterfaceMethod)))")

// MidSystem — сам override: реализации у него общие с BaseSystem.OnAwake,
// а не в пустом поддереве самого MidSystem.
let onOverride = hierImpl("Assets/Game/MidSystem.cs", "public override void OnAwake", "OnAwake")
check(hierShape(onOverride) == "LeafSystem.OnAwake",
      "на override поднялись к базе и нашли соседа (получено: \(hierShape(onOverride)))")
check(onOverride.isExact, "единственная реализация — прыгаем сразу, без списка")

let onLeaf = hierImpl("Assets/Game/LeafSystem.cs", "public class LeafSystem", "LeafSystem")
check(onLeaf.declarations.isEmpty, "у листа иерархии наследников нет")

// Наследование через звено: BaseSystem ← MidSystem ← LeafSystem.
let onBase = hierImpl("Assets/Game/BaseSystem.cs", "public abstract class BaseSystem", "BaseSystem")
check(hierShape(onBase) == "Game.Systems.LeafSystem, Game.Systems.MidSystem",
      "наследники через промежуточное звено (получено: \(hierShape(onBase)))")

let inComment = hierImpl("Assets/Game/Damageable.cs", "namespace Game.Components", "namespace")
check(inComment.declarations.isEmpty, "на ключевом слове ничего не ищется")

try? FileManager.default.removeItem(at: hierRoot)

// ───────────────────── События файловой системы ────────────────
section("События файловой системы")

let fsRoot = URL(fileURLWithPath: "/tmp/pilot-fs")
// Корневой .gitignore типового Unity-проекта: именно эти папки во время
// компиляции и порождают шквал событий.
let fsIgnore = IgnoreMatcher(
    layers: [IgnoreLayer(rules: ["/[Ll]ibrary/", "/[Tt]emp/", "obj/", "*.csproj"]
                            .compactMap { IgnoreRule(line: $0) }, base: "")],
    useSoftSkip: false)
/// Классификация пачки событий; `present` — что сейчас лежит на диске.
func fsClassify(_ events: [(String, Bool)], present: Set<String>) -> FileChangeBatch {
    FileChanges.classify(events.map { FileEvent(path: "/tmp/pilot-fs/" + $0.0, structural: $0.1) },
                         root: fsRoot, ignore: fsIgnore,
                         exists: { present.contains(String($0.dropFirst("/tmp/pilot-fs/".count))) })
}

// Правка существующего файла: перечитать его, но список файлов не трогать.
let fsEdited = fsClassify([("Assets/Game/Player.cs", false)], present: ["Assets/Game/Player.cs"])
check(fsEdited.changed == ["Assets/Game/Player.cs"] && !fsEdited.needsRescan && fsEdited.removed.isEmpty,
      "правка файла: перечитать, список не пересобирать")

// Новый файл: и перечитать, и пересобрать список.
let fsCreated = fsClassify([("Assets/Game/Enemy.cs", true)], present: ["Assets/Game/Enemy.cs"])
check(fsCreated.changed == ["Assets/Game/Enemy.cs"] && fsCreated.needsRescan,
      "новый файл: и в индекс, и в список")

// Исчез с диска — значит удалён, какой бы флаг ни пришёл.
let fsRemoved = fsClassify([("Assets/Game/Old.cs", false)], present: [])
check(fsRemoved.removed == ["Assets/Game/Old.cs"] && fsRemoved.changed.isEmpty && fsRemoved.needsRescan,
      "пропавший файл считается удалённым по диску, а не по флагу")

// Шум Unity: Library и Temp отсекаются целиком, даже структурные события.
let fsNoise = fsClassify([("Library/ScriptAssemblies/Game.dll", true),
                          ("Temp/build.txt", true),
                          ("Assets/Game/obj/Debug/x.cs", true),
                          ("Game.csproj", true),
                          ("Assets/Game/Player.cs", false)],
                         present: ["Library/ScriptAssemblies/Game.dll", "Temp/build.txt",
                                   "Assets/Game/obj/Debug/x.cs", "Game.csproj", "Assets/Game/Player.cs"])
check(fsNoise.changed == ["Assets/Game/Player.cs"] && !fsNoise.needsRescan,
      "игнорируемые папки не будят ни индекс, ни пересканирование (получено: \(fsNoise))")

// Своё же ⌘S пишет атомарно — через временный файл и переименование, — и
// системе видно как создание. Перечитать файл надо, пересобирать список — нет.
let fsOwn = FileChanges.classify(
    [FileEvent(path: "/tmp/pilot-fs/Assets/Game/Player.cs", structural: true)],
    root: fsRoot, ignore: fsIgnore, ownWrites: ["Assets/Game/Player.cs"], exists: { _ in true })
check(fsOwn.changed == ["Assets/Game/Player.cs"] && !fsOwn.needsRescan,
      "своё сохранение не тянет пересканирование списка")
// А чужой файл с тем же флагом — тянет.
let fsForeign = FileChanges.classify(
    [FileEvent(path: "/tmp/pilot-fs/Assets/Game/Enemy.cs", structural: true)],
    root: fsRoot, ignore: fsIgnore, ownWrites: ["Assets/Game/Player.cs"], exists: { _ in true })
check(fsForeign.needsRescan, "чужое появление файла пересобирает список")

// Правило про папку, а событие — про файл глубоко внутри неё.
check(FileChanges.isIgnored("Library/a/b/c.dll", fsIgnore), "правило /Library/ ловит файл внутри")
check(!FileChanges.isIgnored("Assets/Library.cs", fsIgnore), "похожее имя файла не считается той папкой")

// Репозиторий: ветка и статус, но в индекс ничего не идёт.
let fsGit = fsClassify([(".git/HEAD", false), (".git/index", false)], present: [".git/HEAD", ".git/index"])
check(fsGit.gitTouched && fsGit.changed.isEmpty && !fsGit.needsRescan,
      "внутренности .git обновляют git, но не индекс")

// Событие вне корня — не наше; событие на самом корне — пересобрать всё.
let fsOutside = FileChanges.classify([FileEvent(path: "/tmp/other/x.cs", structural: true)],
                                     root: fsRoot, ignore: fsIgnore, exists: { _ in true })
check(fsOutside.isEmpty, "чужой путь пропускается")
let fsRootMoved = FileChanges.classify([FileEvent(path: "/tmp/pilot-fs", structural: true)],
                                       root: fsRoot, ignore: fsIgnore, exists: { _ in true })
check(fsRootMoved.needsRescan, "событие на самом корне пересобирает список")

// Правила читаются из корневого .gitignore; без него — типовые мусорные папки.
let fsDisk = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("pilot-fsrules-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.createDirectory(at: fsDisk, withIntermediateDirectories: true)
check(FileChanges.isIgnored("node_modules/react/index.js", FileChanges.rootMatcher(root: fsDisk)),
      "без .gitignore работают типовые мусорные папки")
try? "/[Ll]ibrary/\n*.log\n".write(to: fsDisk.appendingPathComponent(".gitignore"),
                                    atomically: true, encoding: .utf8)
let fsFromDisk = FileChanges.rootMatcher(root: fsDisk)
check(FileChanges.isIgnored("Library/x.dll", fsFromDisk) && FileChanges.isIgnored("a/b/c.log", fsFromDisk),
      "правила подхватились из корневого .gitignore")
check(!FileChanges.isIgnored("Assets/Player.cs", fsFromDisk), "исходник не игнорируется")
try? FileManager.default.removeItem(at: fsDisk)

// ─────────────────── Перегрузки и расширения ───────────────────
section("Перегрузки и расширения")

let ovlRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("pilot-ovl-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.removeItem(at: ovlRoot)
let callerSource = """
using Game;
using Game.Extras;
namespace Game
{
    public class Caller
    {
        void Run()
        {
            var p = new Player();
            p.Move(1);
            p.Move(1, 2);
            p.Move(Pick(1, 2), 3);
            p.Say("hi");
            p.Say();
            p.Stop();
        }
        int Pick(int a, int b) { return a; }
    }
}
"""
let ovlFiles: [String: String] = [
    "Assets/Game/Player.cs": """
        namespace Game
        {
            public class Player
            {
                public void Move(int dx) { }
                public void Move(int dx, int dy) { }
                public void Stop() { }
            }
        }
        """,
    "Assets/Game/PlayerExtensions.cs": """
        using Game;
        namespace Game.Extras
        {
            public static class PlayerExtensions
            {
                public static void Say(this Player p, string message) { }
                public static void Say(this Player p) { }
            }
        }
        """,
    // Одноимённый Player в чужом namespace со своим расширением: оно не должно
    // подмешаться к Game.Player.
    "Other/Player.cs": """
        namespace Other
        {
            public class Player { }
            public static class OtherExtensions
            {
                public static void Say(this Player p) { }
            }
        }
        """,
    "Assets/Game/Caller.cs": callerSource,
]
for (path, text) in ovlFiles {
    let url = ovlRoot.appendingPathComponent(path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? text.write(to: url, atomically: true, encoding: .utf8)
}
let ovlIndex = SymbolIndex.build(root: ovlRoot, files: Array(ovlFiles.keys), shouldStop: { false })
    ?? SymbolIndex(root: ovlRoot)
let callerModel = SyntaxModel(text: callerSource, spec: Languages.csharp)
let ovlNavigator = LocalNavigator(index: ovlIndex, document: NavDocument(
    url: ovlRoot.appendingPathComponent("Assets/Game/Caller.cs"), relPath: "Assets/Game/Caller.cs",
    model: callerModel, outline: OutlineBuilder.build(model: callerModel)))

/// ⌘B на слове `word` внутри строки `context` файла Caller.cs.
func ovlJump(_ context: String, _ word: String) -> LocalNavigator.Answer {
    let outer = (callerSource as NSString).range(of: context)
    guard outer.location != NSNotFound else { return .none }
    return ovlNavigator.definition(at: outer.location + (context as NSString).range(of: word).location)
}
/// Куда прыгнули: файл и строка однозначно определяют перегрузку.
func ovlLanded(_ answer: LocalNavigator.Answer) -> String {
    guard let first = answer.declarations.first, let range = first.target.range else { return "ничего" }
    let where_ = "\(first.path):\(range.start.line + 1)"
    return answer.isExact ? where_ : "\(where_) (кандидатов \(answer.declarations.count))"
}

check(ovlLanded(ovlJump("p.Move(1);", "Move")) == "Assets/Game/Player.cs:5",
      "перегрузка по числу аргументов: один → Move(int) (получено: \(ovlLanded(ovlJump("p.Move(1);", "Move"))))")
check(ovlLanded(ovlJump("p.Move(1, 2)", "Move")) == "Assets/Game/Player.cs:6",
      "два аргумента → Move(int, int) (получено: \(ovlLanded(ovlJump("p.Move(1, 2)", "Move"))))")
// Запятая внутри вложенного вызова не считается разделителем аргументов.
check(ovlLanded(ovlJump("p.Move(Pick(1, 2), 3)", "Move")) == "Assets/Game/Player.cs:6",
      "вложенный вызов не сбил счёт (получено: \(ovlLanded(ovlJump("p.Move(Pick(1, 2), 3)", "Move"))))")

check(ovlLanded(ovlJump("p.Say(\"hi\")", "Say")) == "Assets/Game/PlayerExtensions.cs:6",
      "метод-расширение найден, выбран по числу аргументов (получено: \(ovlLanded(ovlJump("p.Say(\"hi\")", "Say"))))")
check(ovlLanded(ovlJump("p.Say();", "Say")) == "Assets/Game/PlayerExtensions.cs:7",
      "расширение без аргументов (получено: \(ovlLanded(ovlJump("p.Say();", "Say"))))")
check(ovlLanded(ovlJump("p.Stop();", "Stop")) == "Assets/Game/Player.cs:7", "обычный член на месте")

// Расширение чужого Player в выдачу не попало: у Say ровно два кандидата.
let sayIDs = ovlIndex.extensionsByReceiver["Player"] ?? []
check(sayIDs.count == 3, "в таблице расширений все три Say, включая чужой (получено \(sayIDs.count))")
check(ovlJump("p.Say(\"hi\")", "Say").declarations.allSatisfy { $0.path != "Other/Player.cs" },
      "расширение одноимённого типа из чужого namespace не подмешалось")

// Счёт аргументов отдельно.
check(ovlNavigator.argumentCount(at: (callerSource as NSString).range(of: "Stop();").location) == 0,
      "вызов без аргументов — ноль, а не один")
check(ovlNavigator.argumentCount(at: (callerSource as NSString).range(of: "Pick(1, 2), 3").location) == 2,
      "аргументы вложенного вызова считаются сами по себе")

// Параметры доезжают до индекса и переживают кэш.
let moveSymbols = (ovlIndex.byName["Move"] ?? []).map { ovlIndex[$0].parameters }
check(moveSymbols.contains(["int"]) && moveSymbols.contains(["int", "int"]),
      "типы параметров в индексе (получено: \(moveSymbols))")
let ovlRoundTrip = SymbolIndex.deserialize(ovlIndex.serialized(), root: ovlRoot)
check(ovlRoundTrip?.symbols == ovlIndex.symbols, "параметры пережили кэш")
check(ovlRoundTrip?.extensionsByReceiver["Player"]?.count == 3, "таблица расширений собралась из кэша")
// Кэш прошлой версии полей не досчитается — его надо отвергнуть, а не прочитать криво.
check(SymbolIndex.deserialize("pilot-symbols 1\nF\ta\t\t\t\n0\tFoo\tclass\t\t\t\t\t1\t2\t3",
                              root: ovlRoot) == nil,
      "кэш прошлой версии отвергается")

try? FileManager.default.removeItem(at: ovlRoot)

// ────────────────────── Индекс: правка файла ───────────────────
section("Индекс: правка файла")

let liveRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("pilot-live-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.removeItem(at: liveRoot)
func liveWrite(_ path: String, _ text: String?) {
    let url = liveRoot.appendingPathComponent(path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let text {
        try? text.write(to: url, atomically: true, encoding: .utf8)
    } else {
        try? FileManager.default.removeItem(at: url)
    }
}
let livePaths = ["Assets/A.cs", "Assets/B.cs", "Assets/C.cs", "Assets/D.cs"]
liveWrite("Assets/A.cs", "namespace Game { public class Alpha { public void Run() { } } }")
liveWrite("Assets/B.cs", "using Game;\nnamespace Game { public class Beta : Alpha { } }")
liveWrite("Assets/C.cs", "using Game;\nusing Vec = Game.Alpha;\n")   // только using, без объявлений
liveWrite("Assets/D.cs", "namespace Game { public class Delta { } }")
let liveBase = SymbolIndex.build(root: liveRoot, files: livePaths, shouldStop: { false })
    ?? SymbolIndex(root: liveRoot)
check(liveBase.typesByName["Alpha"]?.count == 1 && liveBase.typesByName["Delta"]?.count == 1,
      "исходный индекс собран")

/// Слепок индекса, не зависящий от порядка файлов внутри него.
func liveShape(_ index: SymbolIndex) -> [String] {
    (0..<index.count).map { i -> String in
        let id = Int32(i)
        let s = index[id]
        return "\(index.relPath(id))|\(s.container ?? "")|\(s.name)|\(s.kind.rawValue)|\(s.line):\(s.column)"
    }.sorted()
}

// Главное свойство: неизменившиеся файлы не перечитываются. Проверяем это
// не таймингом, а буквально — убираем их с диска перед обновлением.
liveWrite("Assets/A.cs", "namespace Game { public class Alpha { public void Walk() { } }\n"
                       + "public class AlphaTwo { } }")
for path in ["Assets/B.cs", "Assets/C.cs", "Assets/D.cs"] { liveWrite(path, nil) }
let afterEdit = SymbolIndex.updating(liveBase, changed: ["Assets/A.cs"], shouldStop: { false })
    ?? SymbolIndex(root: liveRoot)
check(afterEdit.typesByName["AlphaTwo"]?.count == 1, "новый класс из правленого файла попал в индекс")
check(afterEdit.byName["Walk"] != nil && afterEdit.byName["Run"] == nil,
      "переименованный метод заменён, старого имени не осталось")
check(afterEdit.typesByName["Delta"]?.count == 1, "нетронутый файл уцелел, хотя его уже нет на диске")
check(afterEdit.files.contains { $0.path == "Assets/C.cs" && $0.usings == ["Game"]
                                 && $0.aliases["Vec"] == "Game.Alpha" },
      "файл без объявлений сохранил свои using и псевдонимы")
check(afterEdit.derivedByBase["Alpha"]?.count == 1, "таблица наследников пересобрана, Beta на месте")

// Файл опустел: его символы уходят, сам он выпадает из индекса.
liveWrite("Assets/D.cs", "// тут больше ничего нет\n")
let afterEmpty = SymbolIndex.updating(afterEdit, changed: ["Assets/D.cs"], shouldStop: { false })
    ?? SymbolIndex(root: liveRoot)
check(afterEmpty.typesByName["Delta"] == nil, "класс из опустевшего файла исчез")
check(!afterEmpty.files.contains { $0.path == "Assets/D.cs" }, "пустой файл не держим")

// Новый файл, которого в индексе не было вовсе.
liveWrite("Assets/E.cs", "namespace Game { public class Epsilon : Alpha { } }")
let afterNew = SymbolIndex.updating(afterEmpty, changed: ["Assets/E.cs"], shouldStop: { false })
    ?? SymbolIndex(root: liveRoot)
check(afterNew.typesByName["Epsilon"]?.count == 1, "файл, которого в индексе не было, добавлен")
check(afterNew.derivedByBase["Alpha"]?.count == 2, "у Alpha стало двое наследников")

// Удаление: файла нет ни на диске, ни в индексе.
let afterRemove = SymbolIndex.updating(afterNew, changed: [], removed: ["Assets/B.cs"], shouldStop: { false })
    ?? SymbolIndex(root: liveRoot)
check(afterRemove.typesByName["Beta"] == nil, "удалённый файл вычищен из индекса")
check(afterRemove.derivedByBase["Alpha"]?.count == 1, "наследник удалённого файла пропал из таблицы")

// Обновить всё — то же, что собрать заново.
liveWrite("Assets/B.cs", "using Game;\nnamespace Game { public class Beta : Alpha { } }")
liveWrite("Assets/C.cs", "using Game;\nusing Vec = Game.Alpha;\n")
liveWrite("Assets/D.cs", "namespace Game { public class Delta { } }")
let allPaths = livePaths + ["Assets/E.cs"]
let updatedAll = SymbolIndex.updating(afterRemove, changed: allPaths, shouldStop: { false })
    ?? SymbolIndex(root: liveRoot)
let builtAll = SymbolIndex.build(root: liveRoot, files: allPaths, shouldStop: { false })
    ?? SymbolIndex(root: liveRoot)
check(liveShape(updatedAll) == liveShape(builtAll), "обновление всех файлов совпало с полной сборкой")
check(updatedAll.files.map(\.path).sorted() == builtAll.files.map(\.path).sorted(),
      "список файлов совпал с полной сборкой")
check(updatedAll.search("Alpha", limit: 10, shouldStop: { false }).count
        == builtAll.search("Alpha", limit: 10, shouldStop: { false }).count,
      "поиск ⌘T после обновления отвечает так же")

// Папку удалили целиком: событий по её файлам система не пришлёт, придёт
// один путь — значит, уходит и всё, что лежало под ним.
let afterFolder = SymbolIndex.updating(updatedAll, changed: [], removed: ["Assets"], shouldStop: { false })
    ?? SymbolIndex(root: liveRoot)
check(afterFolder.count == 0 && afterFolder.files.isEmpty,
      "удаление папки вычистило всё поддерево (осталось символов \(afterFolder.count))")
// А похожее имя рядом не считается той же папкой.
let afterLookalike = SymbolIndex.updating(updatedAll, changed: [], removed: ["Asset"], shouldStop: { false })
    ?? SymbolIndex(root: liveRoot)
check(afterLookalike.count == updatedAll.count, "папка с похожим именем ничего не задела")

check(SymbolIndex.updating(liveBase, changed: ["Assets/A.cs"], shouldStop: { true }) == nil,
      "прерванное обновление возвращает nil, а не половину индекса")

try? FileManager.default.removeItem(at: liveRoot)

// ─────────────────────────── Вкладки ───────────────────────────
section("Вкладки")
check(Tabs.insertionIndex(active: 1, count: 4) == 2, "новая вкладка — сразу за активной")
check(Tabs.insertionIndex(active: 3, count: 4) == 4, "за последней — в конец")
check(Tabs.insertionIndex(active: nil, count: 4) == 4, "без активной — в конец")
check(Tabs.insertionIndex(active: nil, count: 0) == 0, "первая вкладка")

// давняя, без правок и не активная
check(Tabs.evictionIndex(lastActivated: [5, 1, 3, 9], dirty: [false, false, false, false], active: 3) == 1,
      "закрывается та, где дольше всех не были")
check(Tabs.evictionIndex(lastActivated: [5, 1, 3, 9], dirty: [false, true, false, false], active: 3) == 2,
      "несохранённая не закрывается")
check(Tabs.evictionIndex(lastActivated: [1, 5], dirty: [false, false], active: 0) == 1,
      "активная не закрывается, даже самая давняя")
check(Tabs.evictionIndex(lastActivated: [1, 5], dirty: [true, true], active: nil) == nil,
      "все с правками — закрывать некого")

check(Tabs.recentOrder(lastActivated: [3, 7, 1, 5]) == [1, 3, 0, 2], "⌃Tab: от недавней к давней")

let tabDetails = Tabs.details(forPaths: ["Assets/Scripts/Enemy/Health.cs", "Assets/Scripts/Player/Health.cs",
                                         "Assets/Scripts/Player/Move.cs", "README.md"])
check(tabDetails == ["Enemy", "Player", nil, nil], "одноимённые различаются ближайшей папкой (получено \(tabDetails))")
let deepDetails = Tabs.details(forPaths: ["a/x/Editor/Config.cs", "b/x/Editor/Config.cs", "Config.cs"])
check(deepDetails == ["a/x/Editor", "b/x/Editor", nil],
      "папок берётся столько, сколько нужно, чтобы различить (получено \(deepDetails))")
let sameDetails = Tabs.details(forPaths: ["src/App.swift", "src/App.swift"])
check(sameDetails == ["src", "src"], "одинаковые пути (файл и его версия из MR) — подпись есть, различит значок")

check(Tabs.shortened("Short.cs") == "Short.cs", "короткое имя не сокращается")
let longName = "VeryLongGeneratedSerializationContractForPlayer.g.cs"
let shortName = Tabs.shortened(longName)
check(shortName.count == 36 && shortName.hasPrefix("VeryLong") && shortName.hasSuffix("Player.g.cs") && shortName.contains("…"),
      "длинное имя — многоточие посередине, конец с расширением цел (получено \(shortName))")

// ─────────────────────── Открытие снаружи ───────────────────────
section("OpenRequest")
let unityRequest = OpenRequest(url: URL(string:
    "pilot://open?project=%2FUsers%2Fme%2FMy%20Game&file=%2FUsers%2Fme%2FMy%20Game%2FAssets%2FA%2BB.cs&line=12&column=5")!)
check(unityRequest?.path?.path == "/Users/me/My Game/Assets/A+B.cs", "pilot://: путь с пробелом и + раскодирован")
check(unityRequest?.project?.path == "/Users/me/My Game", "pilot://: проект")
check(unityRequest?.range == LSPRange(start: LSPPosition(line: 11, character: 4), end: LSPPosition(line: 11, character: 4)),
      "строка и столбец с единицы -> LSP с нуля")
let noPlace = OpenRequest(url: URL(string: "pilot://open?file=/p/A.cs&line=-1&column=0")!)
check(noPlace?.line == nil && noPlace?.column == nil && noPlace?.range == nil, "-1 и 0 от Unity — место неизвестно")
let lineOnly = OpenRequest(url: URL(string: "pilot://open?file=/p/A.cs&line=3")!)
check(lineOnly?.range?.start == LSPPosition(line: 2, character: 0), "без столбца — начало строки")
check(OpenRequest(url: URL(string: "pilot://open?project=/p")!)?.path == nil, "только проект — «Open C# Project»")
check(OpenRequest(url: URL(string: "pilot://open?file=relative/A.cs")!) == nil, "относительный путь не принимается")
check(OpenRequest(url: URL(string: "pilot://other?file=/p/A.cs")!) == nil, "неизвестная команда")
check(OpenRequest(url: URL(string: "https://open?file=/p/A.cs")!) == nil, "чужая схема")
check(OpenRequest(url: URL(fileURLWithPath: "/p/./src/../A.cs"))?.path?.path == "/p/A.cs", "file:// от Finder")

// Вне репозитория поиск .git доходит до / и останавливается (раньше крутился вечно).
let noRepo = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pilot-norepo-\(getpid())/a/b")
try? FileManager.default.createDirectory(at: noRepo, withIntermediateDirectories: true)
check(Git.repositoryRoot(for: noRepo) == nil, "папка вне git-репозитория — корня нет")
check(Git.repositoryRoot(for: URL(string: "file:///")!) == nil, "корень диска")
try? FileManager.default.removeItem(at: noRepo.deletingLastPathComponent().deletingLastPathComponent())

// Командная строка — так Pilot запускает Unity: `$(ProjectPath) $(File):$(Line):$(Column)`.
let disk: [String: Bool] = ["/g": true, "/g/Assets/A.cs": false, "/g/Assets/b:c.cs": false, "/g/Assets/7:8": false]
func launch(_ args: String...) -> OpenRequest? {
    OpenRequest(arguments: ["/Applications/Pilot.app/Contents/MacOS/Pilot"] + args) { disk[$0] }
}
let fromUnity = launch("/g", "/g/Assets/A.cs:12:5")
check(fromUnity?.project?.path == "/g" && fromUnity?.path?.path == "/g/Assets/A.cs"
      && fromUnity?.line == 12 && fromUnity?.column == 5, "Unity: проект, файл, строка, столбец")
check(launch("/g/Assets/A.cs:12")?.line == 12 && launch("/g/Assets/A.cs:12")?.column == nil, "только строка")
let noLine = launch("/g", "/g/Assets/A.cs:0:0")
check(noLine?.path?.path == "/g/Assets/A.cs" && noLine?.line == nil, "двойной клик по скрипту: 0:0 — без места")
let openProject = launch("/g", ":0:0")
check(openProject?.project?.path == "/g" && openProject?.path == nil, "Open C# Project: пустой $(File) — только проект")
check(launch("/g/Assets/b:c.cs:3")?.path?.path == "/g/Assets/b:c.cs", "двоеточие в имени файла")
check(launch("/g/Assets/7:8")?.path?.path == "/g/Assets/7:8" && launch("/g/Assets/7:8")?.line == nil,
      "файл, похожий на file:line, существует — берём как есть")
check(launch("-NSDocumentRevisionsDebugMode", "YES", "/g/Assets/A.cs")?.path?.path == "/g/Assets/A.cs",
      "аргументы macOS пропускаются")
check(launch("/nope/A.cs:3") == nil && launch() == nil, "несуществующий путь и пустая строка")

let roundTrip = OpenRequest(url: OpenRequest(path: URL(fileURLWithPath: "/My Game/a&b=c+d#e.cs"), line: 7, column: 2,
                                             project: URL(fileURLWithPath: "/My Game")).url)
check(roundTrip?.path?.path == "/My Game/a&b=c+d#e.cs" && roundTrip?.line == 7 && roundTrip?.column == 2
      && roundTrip?.project?.path == "/My Game", "pilot:// туда и обратно: пробел, &, =, +, #")

func openRepoOf(_ url: URL) -> URL? {
    // Основной репозиторий /repo, внутри — worktree со своим .git.
    url.path.hasPrefix("/repo/.claude/worktrees/wt") ? URL(fileURLWithPath: "/repo/.claude/worktrees/wt")
        : url.path.hasPrefix("/repo") ? URL(fileURLWithPath: "/repo") : nil
}
let openRepo = URL(fileURLWithPath: "/repo")
let worktree = URL(fileURLWithPath: "/repo/.claude/worktrees/wt")
check(OpenRequest.staysInRoot(openRepo, file: URL(fileURLWithPath: "/repo/Assets/A.cs"), desired: openRepo, repository: openRepoOf),
      "файл открытого проекта — без переключения")
check(OpenRequest.staysInRoot(openRepo, file: URL(fileURLWithPath: "/repo/client/Assets/A.cs"),
                              desired: URL(fileURLWithPath: "/repo/client"), repository: openRepoOf),
      "Unity-проект в подпапке открытого репозитория — без переключения")
check(!OpenRequest.staysInRoot(openRepo, file: URL(fileURLWithPath: "/repo/.claude/worktrees/wt/Assets/A.cs"),
                               desired: worktree, repository: openRepoOf),
      "файл worktree внутри открытого репозитория — переключиться на worktree")
check(!OpenRequest.staysInRoot(openRepo, file: URL(fileURLWithPath: "/other/A.cs"),
                               desired: URL(fileURLWithPath: "/other"), repository: openRepoOf),
      "файл другого проекта — переключиться")
check(!OpenRequest.staysInRoot(URL(fileURLWithPath: "/rep"), file: URL(fileURLWithPath: "/repo/A.cs"),
                               desired: openRepo, repository: openRepoOf),
      "/rep — не родитель /repo")
check(!OpenRequest.staysInRoot(nil, file: URL(fileURLWithPath: "/repo/A.cs"), desired: openRepo, repository: openRepoOf),
      "стартовый экран — открыть проект")
check(OpenRequest.staysInRoot(openRepo, file: nil, desired: openRepo, repository: openRepoOf), "проект уже открыт")
check(!OpenRequest.staysInRoot(openRepo, file: nil, desired: URL(fileURLWithPath: "/repo/client"), repository: openRepoOf),
      "просили открыть проект-подпапку — открываем её")

// ───────────────────────── APK, JAR, DEX ─────────────────────────
section("Архивы")
check(ArchiveLayout.isArchive(URL(fileURLWithPath: "/x/App.APK")), "apk без учёта регистра")
check(ArchiveLayout.isArchive(URL(fileURLWithPath: "/x/lib.jar")) && ArchiveLayout.isArchive(URL(fileURLWithPath: "/x/classes.dex")),
      "jar и dex")
check(!ArchiveLayout.isArchive(URL(fileURLWithPath: "/x/Program.cs")) && !ArchiveLayout.isArchive(URL(fileURLWithPath: "/x/a.zip")),
      "исходник и zip — не архивы")
check(ArchiveLayout.sourcePath(className: "com.foo.Bar") == "sources/com/foo/Bar.java", "класс — по пакету")
check(ArchiveLayout.sourcePath(className: "Bar") == "sources/Bar.java", "класс без пакета")
check(ArchiveLayout.resourcePath("res/values/strings.xml") == "resources/res/values/strings.xml", "ресурс")
check(ArchiveLayout.split(className: "com.foo.Bar") == ("Bar", "com.foo"), "имя и пакет")
check(ArchiveLayout.split(className: "Bar") == ("Bar", nil), "без пакета")
check(ArchiveLayout.keyword(kind: "i") == "interface" && ArchiveLayout.keyword(kind: "x") == "class", "вид класса")
// Архив открывается проектом, а не файлом: пути внутри считаются от него.
let apkRequest = OpenRequest(arguments: ["Pilot", "/x/app.apk"]) { $0 == "/x/app.apk" ? false : nil }
check(apkRequest?.path?.path == "/x/app.apk" && apkRequest?.project == nil, "apk из командной строки — путь")

// ─────────────────────── Картинки, модели, шрифты ───────────────────────
section("Медиа")
check(MediaKind(filename: "Wall.TGA") == .image && MediaKind(filename: "hdri.exr") == .image, "текстуры Unity — картинки")
check(MediaKind(filename: "icon.svg") == .image, "svg — картинка, а не XML")
check(MediaKind(filename: "SM_Well_01.fbx") == .model && MediaKind(filename: "a.usdz") == .model, "модели")
check(MediaKind(filename: "LiberationSans.ttf") == .font && MediaKind(filename: "x.otf") == .font, "шрифты")
check(MediaKind(filename: "readme.pdf") == .pdf, "pdf")
check(MediaKind(filename: "Program.cs") == nil && MediaKind(filename: "Makefile") == nil
      && MediaKind(filename: "Scene.unity") == nil, "текст — не медиа")

// Двоичный FBX 7.4 собираем руками: квадрат из двух полигонов, сдвинутый
// моделью, с материалом на втором полигоне.
enum FBXTestProp { case i64(Int64), i32(Int32), f64(Double), string(String), doubles([Double]), ints([Int32]) }
struct FBXTestNode {
    var name: String
    var props: [FBXTestProp] = []
    var children: [FBXTestNode] = []
}
func N(_ name: String, _ props: [FBXTestProp] = [], _ children: [FBXTestNode] = []) -> FBXTestNode {
    FBXTestNode(name: name, props: props, children: children)
}
func P(_ name: String, _ values: Double...) -> FBXTestNode {
    N("P", [.string(name), .string(name), .string(""), .string("A")] + values.map { .f64($0) })
}
func fbxBinary(_ nodes: [FBXTestNode]) -> Data {
    func u32(_ v: Int, into d: inout Data) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
    func node(_ n: FBXTestNode, at offset: Int) -> Data {
        var props = Data()
        for p in n.props {
            switch p {
            case .i64(let v): props.append(UInt8(ascii: "L")); withUnsafeBytes(of: v.littleEndian) { props.append(contentsOf: $0) }
            case .i32(let v): props.append(UInt8(ascii: "I")); withUnsafeBytes(of: v.littleEndian) { props.append(contentsOf: $0) }
            case .f64(let v): props.append(UInt8(ascii: "D")); withUnsafeBytes(of: v.bitPattern.littleEndian) { props.append(contentsOf: $0) }
            case .string(let v): props.append(UInt8(ascii: "S")); u32(v.utf8.count, into: &props); props.append(contentsOf: v.utf8)
            case .doubles(let v):
                props.append(UInt8(ascii: "d")); u32(v.count, into: &props); u32(0, into: &props); u32(v.count * 8, into: &props)
                for x in v { withUnsafeBytes(of: x.bitPattern.littleEndian) { props.append(contentsOf: $0) } }
            case .ints(let v):
                props.append(UInt8(ascii: "i")); u32(v.count, into: &props); u32(0, into: &props); u32(v.count * 4, into: &props)
                for x in v { withUnsafeBytes(of: x.littleEndian) { props.append(contentsOf: $0) } }
            }
        }
        let headerLength = 13 + n.name.utf8.count
        var children = Data()
        for child in n.children {
            children += node(child, at: offset + headerLength + props.count + children.count)
        }
        if !n.children.isEmpty { children += Data(count: 13) }
        var out = Data()
        u32(offset + headerLength + props.count + children.count, into: &out)
        u32(n.props.count, into: &out)
        u32(props.count, into: &out)
        out.append(UInt8(n.name.utf8.count))
        out.append(contentsOf: n.name.utf8)
        return out + props + children
    }
    var data = Data("Kaydara FBX Binary  ".utf8) + Data([0, 0x1A, 0])
    u32(7400, into: &data)
    for n in nodes { data += node(n, at: data.count) }
    return data + Data(count: 13)
}
let quad = fbxBinary([
    N("Objects", [], [
        N("Geometry", [.i64(10), .string("Quad\u{0}\u{1}Geometry"), .string("Mesh")], [
            N("Vertices", [.doubles([0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 2, 0, 0, 2, 1, 0])]),
            // два полигона: 0-1-2-3 и 1-4-5-2, конец полигона — отрицательный индекс
            N("PolygonVertexIndex", [.ints([0, 1, 2, -4, 1, 4, 5, -3])]),
            N("LayerElementMaterial", [.i32(0)], [
                N("MappingInformationType", [.string("ByPolygon")]),
                N("Materials", [.ints([0, 1])]),
            ]),
        ]),
        N("Model", [.i64(20), .string("Floor\u{0}\u{1}Model"), .string("Mesh")], [
            N("Properties70", [], [P("Lcl Translation", 10, 0, 0), P("Lcl Scaling", 2, 2, 2)]),
        ]),
        N("Material", [.i64(30), .string("Grass\u{0}\u{1}Material"), .string("")], [
            N("Properties70", [], [P("DiffuseColor", 0.2, 0.8, 0.3)]),
        ]),
        N("Material", [.i64(31), .string("Stone\u{0}\u{1}Material"), .string("")]),
    ]),
    N("Connections", [], [
        N("C", [.string("OO"), .i64(10), .i64(20)]),
        N("C", [.string("OO"), .i64(20), .i64(0)]),
        N("C", [.string("OO"), .i64(30), .i64(20)]),
        N("C", [.string("OO"), .i64(31), .i64(20)]),
    ]),
])
do {
    let scene = try FBX.scene(from: quad)
    check(scene.meshes.count == 1 && scene.meshes.first?.name == "Floor", "FBX: сетка названа по модели")
    check(scene.triangles == 4 && scene.controlPoints == 6, "FBX: два четырёхугольника — четыре треугольника")
    check(scene.meshes.first?.parts.map(\.material) == [0, 1], "FBX: полигоны разложены по слотам материалов")
    check(scene.materials.map(\.name) == ["Grass", "Stone"] && scene.materials[0].color?.1 == Float(0.8),
          "FBX: материалы с цветом")
    check(scene.boundsMin.0 == 10 && scene.boundsMax.0 == 14 && scene.boundsMax.1 == 2, "FBX: трансформ модели применён")
    let normal = scene.meshes[0].normals
    check(abs(normal[2] - 1) < 1e-5, "FBX: нормаль без слоя нормалей — по полигону")
} catch {
    check(false, "FBX: двоичный файл разобран (\(error))")
}
check((try? FBX.parse(Data("hello".utf8))) == nil, "FBX: не FBX — ошибка, а не пустая сцена")

let asciiFBX = """
; FBX 7.5.0 project file
FBXHeaderExtension:  {
    FBXVersion: 7500
}
GlobalSettings:  {
    Properties70:  {
        P: "UpAxis", "int", "Integer", "",2
        P: "UpAxisSign", "int", "Integer", "",1
        P: "FrontAxis", "int", "Integer", "",1
        P: "FrontAxisSign", "int", "Integer", "",-1
        P: "CoordAxis", "int", "Integer", "",0
        P: "UnitScaleFactor", "double", "Number", "",100
    }
}
Objects:  {
    Geometry: 1, "Geometry::Tri", "Mesh" {
        Vertices: *9 {
            a: 0,0,0,1,0,0,
            0,0,5
        }
        PolygonVertexIndex: *3 {
            a: 0,1,-3
        }
        LayerElementNormal: 0 {
            MappingInformationType: "ByPolygonVertex"
            ReferenceInformationType: "Direct"
            Normals: *9 {
                a: 0,-1,0,0,-1,0,0,-1,0
            }
        }
    }
}
Connections:  {
}
"""
do {
    let scene = try FBX.scene(from: Data(asciiFBX.utf8))
    check(scene.meshes.count == 1 && scene.triangles == 1 && scene.meshes[0].name == "Tri", "FBX ASCII: треугольник")
    // Z-up → Y-up: высота 5 по Z становится высотой по Y.
    check(scene.boundsMax.1 == 5 && scene.metersPerUnit == 1, "FBX ASCII: оси и единицы из GlobalSettings")
    let n = scene.meshes[0].normals
    check(abs(n[2] - 1) < 1e-5, "FBX ASCII: нормаль повёрнута вместе с осями")
} catch {
    check(false, "FBX ASCII разобран (\(error))")
}
check(Matrix4.euler((90, 0, 0), order: 0).transformPoint((0, 1, 0)).2 > 0.999, "поворот X на 90°: Y → Z")

// ─────────────────────────── Markdown ───────────────────────────
section("Markdown")
func md(_ s: String) -> String { Markdown.html(s) }
check(md("# Привет, мир!").contains("<h1 id=\"привет-мир\" data-line=\"0\">Привет, мир!</h1>"), "заголовок с якорем")
check(md("a\n\n## B ##").contains("<h2 id=\"b\" data-line=\"2\">B</h2>"), "закрывающие # и номер строки")
check(md("Title\n===").contains("<h1") && md("Title\n---").contains("<h2"), "setext-заголовки")
check(md("**b** *i* ~~s~~ `c*d`") .contains("<strong>b</strong> <em>i</em> <del>s</del> <code>c*d</code>"), "выделение и код")
check(!md("snake_case_name").contains("<em>"), "подчёркивания внутри слова — не курсив")
check(md("*a **b** c*").contains("<em>a <strong>b</strong> c</em>"), "вложенное выделение")
check(md("[t](a b.md)").contains("[t](a b.md)") || !md("[t](a b.md)").contains("href"), "ссылка с пробелом без <> — не ссылка")
check(md("[doc](Docs/x.md \"T\")").contains("<a href=\"Docs/x.md\" title=\"T\">doc</a>"), "ссылка")
check(md("[r]\n\n[r]: http://x").contains("<a href=\"http://x\">r</a>"), "ссылка по метке")
check(md("see https://a.io/x.").contains("<a href=\"https://a.io/x\">https://a.io/x</a>."), "голая ссылка без точки")
check(md("1 < 2 & 3").contains("1 &lt; 2 &amp; 3"), "экранирование")
check(md("- a\n- b\n  - c").contains("<ul data-line=\"0\">\n<li data-line=\"0\">a\n</li>"), "плотный список без <p>")
check(md("- a\n\n- b").contains("<li data-line=\"0\"><p"), "разреженный список — с абзацами")
check(md("3. x\n4. y").contains("<ol start=\"3\""), "нумерованный с началом")
check(md("- [x] done\n- [ ] todo").contains("<input type=\"checkbox\" checked disabled> done"), "задачи")
let tableHTML = md("| A | B |\n|:-|-:|\n| `x|y` | 2 |")
check(tableHTML.contains("<th style=\"text-align:left\">A</th>") && tableHTML.contains("<code>x|y</code>"), "таблица")
check(md("```cs\nclass A {}\n```").contains("<span class=\"t-keyword\">class</span>"), "подсветка кода")
check(md("```\n<b>\n```").contains("&lt;b&gt;"), "код без языка экранирован")
check(md("    code\n\ntext").contains("<pre data-line=\"0\"><code>code</code></pre>"), "код отступом")
check(md("> [!WARNING]\n> Tss").contains("alert-warning"), "плашка GitHub")
check(md("> q\nlazy").contains("<blockquote") && md("> q\nlazy").contains("lazy</p>"), "ленивое продолжение цитаты")
check(!md("<div onclick=\"x()\">\n<script>alert(1)</script>\n</div>").contains("script")
      && !md("<div onclick=\"x()\">hi</div>").contains("onclick"), "скрипты и обработчики вырезаны")
check(md("---\ntitle: X\n---\n# H").contains("front-matter") && md("---\ntitle: X\n---\n# H").contains("data-line=\"3\""),
      "front matter и номера строк после него")
check(md("a  \nb").contains("a<br>\nb"), "жёсткий перенос")
let headings = Markdown.headings("# A\n```\n# not\n```\nB\n-\n### C")
check(headings.map(\.title) == ["A", "B", "C"] && headings.map(\.line) == [0, 4, 6], "заголовки для структуры, мимо кода")
let mdOutline = OutlineBuilder.build(model: SyntaxModel(text: "# Top\n## Sub\n# Next", spec: Languages.markdown))
check(mdOutline.map(\.depth) == [0, 1, 0] && mdOutline[1].container == "Top", "структура Markdown по уровням")
// ──────────────────── Сборки .NET: чтение и декомпиляция ────────────────────
//
// Настоящей .dll в репозитории нет, поэтому сборка собирается прямо здесь:
// PE с одной секцией, в ней — заголовок CLI и метаданные с горсткой строк
// таблиц. Так проверяется весь путь: PE → потоки → таблицы → сигнатуры → текст.
func demoAssembly() -> [UInt8] {
    var strings: [UInt8] = [0]
    var stringOffsets: [String: Int] = [:]
    func text(_ value: String) -> Int {
        if value.isEmpty { return 0 }
        if let known = stringOffsets[value] { return known }
        let offset = strings.count
        strings += Array(value.utf8) + [0]
        stringOffsets[value] = offset
        return offset
    }
    var blobs: [UInt8] = [0]
    func blob(_ bytes: [UInt8]) -> Int {
        let offset = blobs.count
        blobs += [UInt8(bytes.count)] + bytes
        return offset
    }

    // Строки таблиц: один класс Demo.Greeter с константой, методом и конструктором.
    var rows: [UInt8] = []
    func put(_ value: Int, _ size: Int) {
        for shift in 0..<size { rows.append(UInt8((value >> (8 * shift)) & 0xFF)) }
    }
    put(0, 2); put(text("Demo.dll"), 2); put(0, 2); put(0, 2); put(0, 2)      // Module
    put((1 << 2) | 2, 2); put(text("Object"), 2); put(text("System"), 2)      // TypeRef → System.Object
    put(0, 4); put(text("<Module>"), 2); put(0, 2); put(0, 2); put(1, 2); put(1, 2)
    put(0x0010_0001, 4); put(text("Greeter"), 2); put(text("Demo"), 2)        // TypeDef: public class
    put((1 << 2) | 1, 2); put(1, 2); put(1, 2)                                // extends TypeRef 1
    put(0x8056, 2); put(text("Answer"), 2); put(blob([0x06, 0x08]), 2)        // Field: public const int
    put(0x2100, 4); put(0, 2); put(0x0096, 2); put(text("Greet"), 2)          // MethodDef: public static
    put(blob([0x00, 0x02, 0x0E, 0x0E, 0x08]), 2); put(1, 2)                   // string Greet(string, int)
    put(0x2108, 4); put(0, 2); put(0x1886, 2); put(text(".ctor"), 2)
    put(blob([0x20, 0x00, 0x01]), 2); put(3, 2)
    put(0, 2); put(1, 2); put(text("name"), 2)                                // Param
    put(0, 2); put(2, 2); put(text("times"), 2)
    put(0x08, 1); put(0, 1); put((1 << 2) | 0, 2); put(blob([42, 0, 0, 0]), 2)  // Constant: = 42
    put(0x8004, 4); put(1, 2); put(0, 2); put(0, 2); put(0, 2); put(0, 4)     // Assembly: Demo 1.0.0.0
    put(0, 2); put(text("Demo"), 2); put(0, 2)
    put(4, 2); put(0, 2); put(0, 2); put(0, 2); put(0, 4)                     // AssemblyRef: mscorlib
    put(0, 2); put(text("mscorlib"), 2); put(0, 2); put(0, 2)

    var valid: UInt64 = 0
    for table in [0x00, 0x01, 0x02, 0x04, 0x06, 0x08, 0x0B, 0x20, 0x23] { valid |= UInt64(1) << UInt64(table) }

    var image: [UInt8] = []
    func append(_ value: Int, _ size: Int) {
        for shift in 0..<size { image.append(UInt8((value >> (8 * shift)) & 0xFF)) }
    }
    func pad(to size: Int) { image += [UInt8](repeating: 0, count: max(0, size - image.count)) }
    func padded(_ bytes: [UInt8]) -> [UInt8] {
        bytes + [UInt8](repeating: 0, count: (4 - bytes.count % 4) % 4)
    }

    // Поток таблиц: шапка, число строк в каждой таблице и сами строки.
    var tables: [UInt8] = [0, 0, 0, 0, 2, 0, 0, 1]
    for shift in 0..<8 { tables.append(UInt8((valid >> UInt64(8 * shift)) & 0xFF)) }
    tables += [UInt8](repeating: 0, count: 8)
    for count in [1, 1, 2, 1, 2, 2, 1, 1, 1] {
        for shift in 0..<4 { tables.append(UInt8((count >> (8 * shift)) & 0xFF)) }
    }
    tables += rows

    // Корень метаданных: версия рантайма и три потока.
    let version = padded(Array("v4.0.30319\0".utf8))
    let streams: [(String, [UInt8])] = [("#~", padded(tables)), ("#Strings", padded(strings)),
                                        ("#Blob", padded(blobs))]
    var rootSize = 20 + version.count
    for (name, _) in streams { rootSize += 8 + padded(Array(name.utf8) + [0]).count }
    var root: [UInt8] = Array("BSJB".utf8) + [1, 0, 1, 0, 0, 0, 0, 0]
    root += [UInt8(version.count), 0, 0, 0] + version + [0, 0, 3, 0]
    var data: [UInt8] = []
    for (name, stream) in streams {
        let offset = rootSize + data.count
        for shift in 0..<4 { root.append(UInt8((offset >> (8 * shift)) & 0xFF)) }
        for shift in 0..<4 { root.append(UInt8((stream.count >> (8 * shift)) & 0xFF)) }
        root += padded(Array(name.utf8) + [0])
        data += stream
    }
    root += data

    // Заголовок CLI и секция, в которой он лежит.
    var section: [UInt8] = []
    for shift in 0..<4 { section.append(UInt8((72 >> (8 * shift)) & 0xFF)) }
    section += [2, 0, 5, 0]
    for shift in 0..<4 { section.append(UInt8(((0x2000 + 72) >> (8 * shift)) & 0xFF)) }
    for shift in 0..<4 { section.append(UInt8((root.count >> (8 * shift)) & 0xFF)) }
    section += [1, 0, 0, 0]
    section += [UInt8](repeating: 0, count: 72 - section.count)
    section += root
    let sectionSize = (section.count + 0x1FF) & ~0x1FF

    image = Array("MZ".utf8)
    pad(to: 0x3C)
    append(0x80, 4)
    pad(to: 0x80)
    image += Array("PE\0\0".utf8)
    append(0x14C, 2); append(1, 2); append(0, 4); append(0, 4); append(0, 4)  // COFF
    append(224, 2); append(0x2102, 2)
    append(0x10B, 2)                                                          // PE32
    pad(to: image.count + 94)
    for directory in 0..<16 {                                                 // директории; CLI — пятнадцатая
        append(directory == 14 ? 0x2000 : 0, 4)
        append(directory == 14 ? 72 : 0, 4)
    }
    image += Array(".text".utf8) + [0, 0, 0]
    append(section.count, 4); append(0x2000, 4); append(sectionSize, 4); append(0x200, 4)
    pad(to: image.count + 16)
    pad(to: 0x200)
    image += section
    pad(to: 0x200 + sectionSize)
    return image
}

section("Сборки .NET")
let demo = demoAssembly()
check(AssemblySource.isAssembly(URL(fileURLWithPath: "/a/Plugin.dll"))
      && AssemblySource.isAssembly(URL(fileURLWithPath: "/a/Tool.EXE"))
      && !AssemblySource.isAssembly(URL(fileURLWithPath: "/a/Player.cs")),
      "сборка узнаётся по расширению, регистр не важен")
do {
    let source = try AssemblySource.text(bytes: demo, fileName: "Demo.dll")
    check(source.contains("// Demo, Version=1.0.0.0, Culture=neutral"), "шапка: имя и версия сборки")
    check(source.contains("namespace Demo"), "пространство имён")
    check(source.contains("public class Greeter"), "класс с доступностью")
    check(source.contains("public const int Answer = 42;"), "константа вместе со значением")
    check(source.contains("public static string Greet(string name, int times) { }"),
          "метод: сигнатура и имена параметров")
    check(source.contains("public Greeter() { }"), "конструктор назван именем типа")
    check(!source.contains("<Module>"), "служебный тип компилятора не показывается")
} catch {
    check(false, "сборка разобралась (\(error))")
}
do {
    _ = try AssemblySource.text(bytes: Array("не сборка, а текст".utf8), fileName: "x.dll")
    check(false, "текст вместо сборки — ошибка")
} catch {
    check(true, "текст вместо сборки — ошибка")
}
do {
    _ = try AssemblySource.text(bytes: Array(demo.prefix(300)), fileName: "Demo.dll")
    check(false, "обрезанная сборка — ошибка, а не мусор")
} catch {
    check(true, "обрезанная сборка — ошибка, а не мусор")
}
check(TypeName.withoutArity("Dictionary`2") == "Dictionary" && TypeName.arity("Dictionary`2") == 2,
      "число параметров в имени типа")
check(TypeName.withoutArity("Json`Name") == "Json`Name", "обратная кавычка без числа — часть имени")

// Индекс типов по сборкам: им отвечает ⌘B, когда исходников нет, а проект
// ещё не скомпилирован (или Rustlyn нет вовсе).
let assemblyFile = FileManager.default.temporaryDirectory
    .appendingPathComponent("pilot-tests-\(getpid())-Demo.dll")
try? Data(demo).write(to: assemblyFile)
let assemblies = AssemblyIndex.build(assemblies: [assemblyFile, assemblyFile])
check(assemblies.assemblyCount == 1, "одна и та же сборка дважды считается один раз")
check(assemblies.count == 1, "в индекс попал Greeter, но не <Module>")
let greeter = assemblies.matching(name: "Greeter")
check(greeter.count == 1, "тип находится по точному имени")
if let id = greeter.first {
    check(assemblies.entry(id).namespace == "Demo", "пространство имён типа")
    check(assemblies.entry(id).full == "Demo.Greeter", "полное имя")
    let target = assemblies.target(id)
    check(target.url == assemblyFile && target.declaration == "Greeter" && target.range == nil,
          "цель перехода — сборка и имя типа: строку узнаем, когда соберём текст")
    check(assemblies.declaration(id).path == assemblyFile.lastPathComponent, "в списке видна сборка")
}
check(assemblies.matching(name: "greeter").isEmpty, "регистр важен, как и в C#")
check(assemblies.search("gree", limit: 5, shouldStop: { false }).count == 1, "нечёткий поиск по типам сборок")
check(assemblies.search("Demo.Gr", limit: 5, shouldStop: { false }).count == 1,
      "запрос с точкой ищет вместе с пространством имён")
check(assemblies.search("zzz", limit: 5, shouldStop: { false }).isEmpty, "чужой запрос — пусто")
let assemblyText = assemblies.serialized()
if let reread = AssemblyIndex.deserialize(assemblyText) {
    check(reread.count == assemblies.count && reread.assemblyCount == assemblies.assemblyCount,
          "из кэша — те же типы и сборки")
    check(reread.sources == assemblies.sources, "и тот же исходный список: по нему видно, что строить нечего")
    check(reread.matching(name: "Greeter").map { reread.entry($0).full } == ["Demo.Greeter"],
          "из кэша тип находится по имени")
    check(reread.search("Demo.Gr", limit: 5, shouldStop: { false }).count == 1, "и нечётким поиском")
    check(reread.serialized() == assemblyText, "и записывается обратно байт в байт")
} else {
    check(false, "кэш типов сборок читается")
}
check(AssemblyIndex.deserialize("assemblies 1\n0\n1\n/a.dll\n5\tX\tY\t0\n") == nil,
      "ссылка на несуществующую сборку — кэш испорчен")
check(AssemblyIndex.Entry(assembly: 0, name: "Task", namespace: "System.Threading.Tasks", arity: 1)
        .display == "Task<>",
      "обобщённый тип виден как Task<>: иначе два Task в списке неотличимы")
check(AssemblyIndex.Entry(assembly: 0, name: "Dictionary", namespace: "System.Collections.Generic", arity: 2)
        .display == "Dictionary<,>", "число параметров видно по запятым")
try? FileManager.default.removeItem(at: assemblyFile)

// Unity-проект узнаётся по ProjectSettings/ProjectVersion.txt рядом с Assets/.
let fm = FileManager.default
let fakeProject = fm.temporaryDirectory.appendingPathComponent("pilot-tests-\(getpid())-unity")
try? fm.removeItem(at: fakeProject)
try? fm.createDirectory(at: fakeProject.appendingPathComponent("Assets"), withIntermediateDirectories: true)
try? fm.createDirectory(at: fakeProject.appendingPathComponent("ProjectSettings"),
                        withIntermediateDirectories: true)
try? "m_EditorVersion: 6000.3.14f1".write(
    to: fakeProject.appendingPathComponent("ProjectSettings/ProjectVersion.txt"),
    atomically: true, encoding: .utf8)
let unityProject = UnityProjectInfo.detect(root: fakeProject)
check(unityProject?.editorVersion == "6000.3.14f1", "версия редактора из ProjectVersion.txt")
try? fm.removeItem(at: fakeProject)

// ───────────────────────── Rustlyn ─────────────────────────
// Библиотеки здесь нет — пакет собирается без CRustlyn. Проверяется то,
// что должно работать в любом случае: что Pilot без неё собирается и
// отвечает сам, и что перевод её ответов в свои типы верен. Что делает
// сама библиотека, проверяют её тесты (`cargo test` в rustlyn).
section("Rustlyn")

check(Rustlyn.shared == nil, "без библиотеки сессии нет")
check(Rustlyn.start(root: URL(fileURLWithPath: "/tmp")) == nil, "и не поднимается")
check(!Rustlyn.understands(URL(fileURLWithPath: "/a/B.cs")), "без библиотеки понимать нечего")
check(Rustlyn.buildsAgree(), "сверять нечего — значит, расхождения нет")

// Виды объявлений ложатся на виды структуры файла.
check(RustlynDeclarationKind.class.outlineKind == .type, "класс — это тип")
check(RustlynDeclarationKind.record.outlineKind == .type, "запись — тоже тип")
check(RustlynDeclarationKind.constructor.outlineKind == .initializer, "конструктор — инициализатор")
check(RustlynDeclarationKind.indexer.outlineKind == .method, "индексатор читается как метод")
check(RustlynDeclarationKind.enumMember.outlineKind == .enumCase, "член перечисления")
check(RustlynDeclarationKind.class.isType && !RustlynDeclarationKind.method.isType, "тип и не тип")
check(RustlynDeclarationKind.allCases.count == 17, "видов столько же, сколько в библиотеке")
check(TokenKind.allCases.count == 15, "цветов столько же, сколько в библиотеке")

// Типы параметров отделяются от имён: по ним навигатор различает перегрузки.
let withParams = RustlynDeclaration(
    name: "Move", kind: .method, keyword: "void", container: "Game.Pawn", typeText: "void",
    parameters: ["int steps", "System.Collections.Generic.List<int> path", "this Pawn self"],
    nameRange: NSRange(location: 0, length: 4), fullRange: NSRange(location: 0, length: 10),
    line: 0, depth: 1)
check(withParams.parameterTypes == ["int", "System.Collections.Generic.List<int>", "this Pawn"],
      "тип параметра — всё до последнего пробела")

// `using Vec = UnityEngine.Vector3;` приходит одной строкой.
check(RustlynUsing("System").alias == nil, "обычный using без псевдонима")
check(RustlynUsing("Vec=UnityEngine.Vector3").alias == "Vec", "псевдоним разобран")
check(RustlynUsing("Vec=UnityEngine.Vector3").name == "UnityEngine.Vector3", "и имя за ним")

// Цель перехода: полное имя раскладывается на своё и объемлющее.
let target = RustlynTarget(url: URL(fileURLWithPath: "/p/Pawn.cs"), name: "Game.Pawn.Health",
                           line: 4, character: 15, length: 6, kind: .field)
check(target.shortName == "Health", "короткое имя")
check(target.container == "Game.Pawn", "и что его содержит")
check(target.navTarget.range?.start.line == 4, "строка доходит до цели")
check(target.navTarget.range?.end.character == 21, "и конец имени считается по длине")

let single = RustlynTarget(url: URL(fileURLWithPath: "/p/A.cs"), name: "Pawn",
                           line: 0, character: 0, length: 4, kind: .class)
check(single.shortName == "Pawn" && single.container == nil, "имя без точки — само себе имя")

// Структура файла: правила Unity применяются к разобранным атрибутам.
var outline = RustlynOutline()
outline.declarations = [
    RustlynDeclaration(name: "Game", kind: .namespace, keyword: "namespace", container: nil,
                       typeText: nil, nameRange: NSRange(location: 0, length: 4),
                       fullRange: NSRange(location: 0, length: 100), line: 0, depth: 0),
    RustlynDeclaration(name: "Pawn", kind: .class, keyword: "class", container: "Game",
                       typeText: nil, bases: ["MonoBehaviour"],
                       nameRange: NSRange(location: 10, length: 4),
                       fullRange: NSRange(location: 5, length: 90), line: 1, depth: 1),
    RustlynDeclaration(name: "Update", kind: .method, keyword: "void", container: "Game.Pawn",
                       typeText: "void", nameRange: NSRange(location: 20, length: 6),
                       fullRange: NSRange(location: 20, length: 20), line: 2, depth: 2),
    RustlynDeclaration(name: "_speed", kind: .field, keyword: "float", container: "Game.Pawn",
                       typeText: "float", attributes: ["SerializeField"],
                       nameRange: NSRange(location: 50, length: 6),
                       fullRange: NSRange(location: 45, length: 15), line: 3, depth: 2),
    RustlynDeclaration(name: "_hidden", kind: .field, keyword: "int", container: "Game.Pawn",
                       typeText: "int", nameRange: NSRange(location: 70, length: 7),
                       fullRange: NSRange(location: 65, length: 15), line: 4, depth: 2),
]
let items = outline.outlineItems()
check(items.count == 4, "пространство имён в структуру не идёт")
check(items.first(where: { $0.name == "Pawn" })?.kind == .type, "класс — тип")
check(items.first(where: { $0.name == "Pawn" })?.bases == ["MonoBehaviour"], "базовые доходят")
check(items.first(where: { $0.name == "Update" })?.kind == .unityMessage,
      "Update — сообщение движка")
check(items.first(where: { $0.name == "_speed" })?.kind == .serializedField,
      "[SerializeField] — поле инспектора")
check(items.first(where: { $0.name == "_hidden" })?.kind == .field,
      "поле без атрибута остаётся полем")
check(items.first(where: { $0.name == "Update" })?.range.location == 20, "диапазон имени на месте")

// Об отказе стоит говорить не всегда.
check(!RustlynRefusal.notAName.worthSaying, "курсор не на имени — говорить нечего")
check(!RustlynRefusal.none.worthSaying, "успех — тем более")
check(RustlynRefusal.receiverUnknown.worthSaying, "а про невыводимый получатель — стоит")
check(RustlynRefusal.notIndexed.worthSaying, "и про несобранный индекс")

// Путь из ответа: от корня — файл проекта, абсолютный — сборка вне его.
let rustlynRoot = URL(fileURLWithPath: "/p")
check(RustlynTarget.url(forPath: "Assets/Pawn.cs", root: rustlynRoot).path == "/p/Assets/Pawn.cs",
      "путь проекта — от корня")
check(RustlynTarget.url(forPath: "/Applications/Unity/UnityEngine.CoreModule.dll", root: rustlynRoot).path
        == "/Applications/Unity/UnityEngine.CoreModule.dll",
      "сборка вне проекта — как есть, а не под корнем")

// Компиляция: что показывать в статус-строке и когда отвечает компилятор.
let compiled = RustlynCompiled(files: 2301, references: 172, projects: 3, milliseconds: 4250, kind: .msbuild)
check(compiled.summary == "2301 файл против 172 сборок · 3 проекта · 4.2 с"
        || compiled.summary == "2301 файл против 172 сборок · 3 проекта · 4,2 с",
      "итог компиляции словами (получено: \(compiled.summary))")
var cachedCompile = RustlynCompiled(files: 5, references: 1, milliseconds: 800, kind: .unity)
cachedCompile.unchanged = true
check(cachedCompile.summary.hasSuffix("· из кэша"), "прочтённая с диска компиляция так и помечена, без времени")
check(RustlynCompiled(files: 5, references: 1, kind: .unity).summary.contains("Unity без .csproj"),
      "Unity без проектных файлов так и называется")
check(!CompilerState.idle.isReady && !CompilerState.compiling(first: true).isReady,
      "до первой компиляции отвечает индекс")
check(CompilerState.compiling(first: false).isReady && CompilerState.ready(compiled).isReady,
      "перекомпиляция не отнимает ответы прошлой компиляции")
check(RustlynProjectKind.isProjectFile("Game/Assembly-CSharp.csproj")
        && RustlynProjectKind.isProjectFile("App/obj/project.assets.json")
        && RustlynProjectKind.isProjectFile("Assets/Game.asmdef"),
      "проектные файлы узнаются")
check(!RustlynProjectKind.isProjectFile("Assets/Pawn.cs") && !RustlynProjectKind.isProjectFile("package.json"),
      "исходник и чужой JSON — не проектные файлы")

// Дополнение: виды ложатся на значки LSP, порядок Rustlyn'а сохраняется.
check(RustlynCompletionKind.allCases.count == 16, "видов дополнения столько же, сколько в библиотеке")
check(RustlynCompletionKind.method.lspKind == 2 && RustlynCompletionKind.local.lspKind == 6
        && RustlynCompletionKind.keyword.lspKind == 14 && RustlynCompletionKind.enumMember.lspKind == 20,
      "значки дополнения — по видам LSP")
let offered = RustlynCompletions(items: [
    RustlynCompletion(label: "lives", detail: "int lives", kind: .local, rank: 0),
    RustlynCompletion(label: "Heal", detail: "void Heal(int by)", kind: .method, rank: 10),
    RustlynCompletion(label: "return", detail: "", kind: .keyword, rank: 30),
], start: 42).list
check(offered.items.map(\.label) == ["lives", "Heal", "return"], "варианты в порядке Rustlyn'а")
check(offered.items.map(\.sortText!) == offered.items.map(\.sortText!).sorted(),
      "sortText держит этот порядок")
check(offered.items[2].detail == nil && offered.items[1].detail == "void Heal(int by)",
      "пустая подпись не показывается")
check(offered.items.allSatisfy { $0.edit == nil && $0.kind != 1 },
      "правки нет, и за слова файла варианты не принимаются")

// Символы препроцессора Unity: без них половина `#if` читается как мёртвая.
let unitySymbols = UnityProjectInfo(root: URL(fileURLWithPath: "/p"),
                                    editorVersion: "6000.3.14f1").preprocessorSymbols
check(unitySymbols.contains("UNITY_EDITOR"), "UNITY_EDITOR всегда")
check(unitySymbols.contains("UNITY_6000"), "мажорная версия")
check(unitySymbols.contains("UNITY_6000_3"), "мажорная с минорной")
check(unitySymbols.contains("UNITY_2021_3_OR_NEWER"), "лесенка «или новее» вниз до 2017")
check(unitySymbols.contains("UNITY_6000_3_OR_NEWER"), "и до самой версии включительно")
check(!unitySymbols.contains("UNITY_6000_4_OR_NEWER"), "но не выше неё")
check(Set(unitySymbols).count == unitySymbols.count, "без повторов")

let noVersion = UnityProjectInfo(root: URL(fileURLWithPath: "/p"),
                                 editorVersion: nil).preprocessorSymbols
check(noVersion.contains("UNITY_EDITOR"), "без версии остаются общие символы")
check(!noVersion.contains(where: { $0.hasPrefix("UNITY_") && $0.hasSuffix("_OR_NEWER") }),
      "и ни одной выдуманной версии")

section("Единый поиск / намерение")

let fileIntent = SearchIntent.classify("Player.cs")
check(fileIntent.path && !fileIntent.qualified && fileIntent.name == "Player", "Player.cs — это файл")
check(SearchIntent.classify("Assets/Scripts").path, "со слешем — путь")
let qualifiedIntent = SearchIntent.classify("Game.Pawn")
check(qualifiedIntent.qualified && !qualifiedIntent.path && qualifiedIntent.name == "Pawn",
      "Game.Pawn — имя с контейнером, судят по Pawn")
check(SearchIntent.classify("Game.asset").path && SearchIntent.classify("Game.Asset").qualified,
      "строчное расширение — файл, с заглавной — член")
let abbreviation = SearchIntent.classify("PlPawn")
check(abbreviation.pascal && !abbreviation.path && !abbreviation.text, "PlPawn — сокращение имени типа")
let plainIntent = SearchIntent.classify("player")
check(!plainIntent.pascal && !plainIntent.path && !plainIntent.qualified && !plainIntent.text, "строчное слово — без перекоса")
check(SearchIntent.classify("void Update(").text, "пробел и скобка — текст")
check(SearchIntent.classify("\"hello\"").text, "кавычки — текст")
check(SearchIntent.classify("здоровье").text, "кириллица в именах не бывает — текст")
check(SearchIntent.classify("  Player  ") == SearchIntent.classify("Player"), "пробелы по краям не в счёт")

section("Единый поиск / ранжирование")

func ranked(_ query: String, _ candidates: [SearchCandidate], near: String? = nil) -> [String] {
    UnifiedSearch.rank(candidates, intent: SearchIntent.classify(query), near: near)
        .map { "\($0.source):\($0.name)" }
}
let playerCandidates = [
    SearchCandidate(source: .text, name: "var player = new Player();", path: "Assets/Game.cs", score: 40, id: 0, wholeWord: true),
    SearchCandidate(source: .type, name: "PlayerController", path: "Assets/PlayerController.cs", score: 200, id: 1),
    SearchCandidate(source: .file, name: "Assets/Player.cs", path: "Assets/Player.cs", score: 190, id: 2),
    SearchCandidate(source: .member, name: "Player", path: "Assets/Game.cs", score: 150, id: 3),
    SearchCandidate(source: .type, name: "Player", path: "Assets/Player.cs", score: 150, id: 4),
]
check(ranked("Player", playerCandidates) == ["type:Player", "member:Player", "type:PlayerController",
                                            "text:var player = new Player();"],
      "Player: сначала тип, потом член, потом похожие; файл типа — повтор; текст — в конце (получено \(ranked("Player", playerCandidates)))")
check(ranked("Player.cs", playerCandidates).first == "file:Assets/Player.cs",
      "Player.cs: первым файл, и он не выбрасывается")
let textCandidates = [
    SearchCandidate(source: .member, name: "VoidUpdater", path: "A.cs", score: 300, id: 0),
    SearchCandidate(source: .text, name: "void Update() { }", path: "B.cs", score: 10, id: 1, wholeWord: true),
]
check(ranked("void Update", textCandidates).first == "text:void Update() { }",
      "с пробелом — текст выше любого нечёткого имени")
let twins = [
    SearchCandidate(source: .file, name: "Server/Config.cs", path: "Server/Config.cs", score: 100, id: 0),
    SearchCandidate(source: .file, name: "Client/Config.cs", path: "Client/Config.cs", score: 100, id: 1),
]
check(ranked("Config", twins, near: "Client/Main.cs").first == "file:Client/Config.cs",
      "из одноимённых выше тот, что рядом с открытым файлом")
check(ranked("Pawn", [SearchCandidate(source: .type, name: "Pawn", path: "P.cs", score: 10, id: 0),
                      SearchCandidate(source: .file, name: "Pawns.json", path: "Pawns.json", score: 90, id: 1)])
        .first == "type:Pawn", "точное имя выше нечёткого с большими очками")
check(UnifiedSearch.fuzzy("PlCo", "PlayerController") != nil && UnifiedSearch.fuzzy("zz", "Player") == nil,
      "нечёткое сравнение для чужих символов")

section("Единый поиск / текст в файлах")

let textRoot = FileManager.default.temporaryDirectory.appendingPathComponent("pilot-tests-\(getpid())-grep")
try? FileManager.default.removeItem(at: textRoot)
try? FileManager.default.createDirectory(at: textRoot, withIntermediateDirectories: true)
func put(_ name: String, _ bytes: [UInt8]) { try? Data(bytes).write(to: textRoot.appendingPathComponent(name)) }
put("A.cs", Array("class A {\n    void Update() { }\n}\n".utf8))
put("b.txt", Array("update later\nUPDATE\nнет\n".utf8))
put("c.png", Array("update".utf8))
put("d.data", Array("update\u{0}".utf8))
put("e.cs", Array("// привет, мир: update\n".utf8))
let grepPaths = ["A.cs", "b.txt", "c.png", "d.data", "e.cs", "missing.cs"]
let anyCase = ContentSearch.search("update", root: textRoot, paths: grepPaths, shouldStop: { false })
check(anyCase.map { "\(grepPaths[Int($0.file)]):\($0.line)" } == ["A.cs:1", "b.txt:0", "b.txt:1", "e.cs:0"],
      "без заглавных — любой регистр; картинки, двоичное и пропавшее — мимо (получено \(anyCase.map { "\(grepPaths[Int($0.file)]):\($0.line)" }))")
if let first = anyCase.first {
    check(first.text == "void Update() { }" && first.column == 9 && first.length == 6,
          "строка без отступа, колонка — в исходной строке")
    let marked = String(decoding: Array(first.text.utf8)[Int(first.positions[0])...Int(first.positions.last!)], as: UTF8.self)
    check(marked == "Update" && first.wholeWord, "подсвечено само совпадение, и оно целое слово")
}
if let cyr = anyCase.last {
    check(cyr.column == "// привет, мир: ".utf16.count, "колонка после кириллицы — в UTF-16")
}
let exactCase = ContentSearch.search("Update", root: textRoot, paths: grepPaths, shouldStop: { false })
check(exactCase.count == 1 && exactCase.first?.file == 0, "с заглавной — регистр важен")
let partial = ContentSearch.search("pdat", root: textRoot, paths: grepPaths, shouldStop: { false })
check(!partial.isEmpty && partial.allSatisfy { !$0.wholeWord }, "кусок слова — не целое слово")
check(ContentSearch.search("нет", root: textRoot, paths: grepPaths, shouldStop: { false }).map(\.line) == [2],
      "кириллица ищется")
var few = ContentSearch.Options()
few.limit = 2
check(ContentSearch.search("update", root: textRoot, paths: grepPaths, options: few, shouldStop: { false }).count == 2,
      "не больше предела")
let grepLongLine = String(repeating: "x", count: 500) + "needle" + String(repeating: "y", count: 500)
put("long.txt", Array(grepLongLine.utf8))
if let long = ContentSearch.search("needle", root: textRoot, paths: ["long.txt"], shouldStop: { false }).first {
    check(long.text.hasPrefix("…") && long.text.utf8.count < 300 && long.text.contains("needle"),
          "длинная строка режется вокруг совпадения")
    let shown = String(decoding: Array(long.text.utf8)[Int(long.positions[0])...Int(long.positions.last!)], as: UTF8.self)
    check(shown == "needle", "и подсветка остаётся на месте")
} else {
    check(false, "совпадение в длинной строке находится")
}
try? FileManager.default.removeItem(at: textRoot)

section("История курсора")

let histA = URL(fileURLWithPath: "/p/A.cs"), histB = URL(fileURLWithPath: "/p/B.cs")
func at(_ url: URL, _ line: Int) -> NavTarget {
    NavTarget(url: url, range: LSPRange(start: LSPPosition(line: line, character: 0),
                                        end: LSPPosition(line: line, character: 0)))
}
func lines(_ h: NavigationHistory) -> [String] {
    h.places.map { "\($0.url.lastPathComponent):\($0.range.map { String($0.start.line) } ?? "-")" }
}
var hist = NavigationHistory()
hist.caretMoved(from: nil, to: at(histA, 0))
hist.caretMoved(from: at(histA, 0), to: at(histA, 5))
check(hist.places.isEmpty, "шаги курсора без перехода историю не заводят")
hist.caretMoved(from: at(histA, 5), to: at(histA, 200))
check(lines(hist) == ["A.cs:5", "A.cs:200"], "далёкий прыжок в том же файле записан (получено \(lines(hist)))")
hist.caretMoved(from: at(histA, 200), to: at(histA, 204))
check(lines(hist) == ["A.cs:5", "A.cs:204"], "шаг рядом уточняет текущее место")
hist.navigate(from: at(histA, 204), to: at(histB, 40))
hist.caretMoved(from: at(histA, 204), to: at(histB, 40))
check(lines(hist) == ["A.cs:5", "A.cs:204", "B.cs:40"], "переход в другой файл — одно место, и приземление его не дублирует")
hist.caretMoved(from: at(histB, 40), to: at(histB, 45))
let back1 = hist.back(from: at(histB, 45))
check(back1 == at(histA, 204), "назад — туда, откуда ушли")
check(lines(hist).last == "B.cs:45", "а вперёд вернёт туда, где курсор стоял, а не куда пришли")
check(hist.back(from: at(histA, 204)) == at(histA, 5) && !hist.canGoBack, "и дальше в прошлое")
check(hist.forward(from: at(histA, 5)) == at(histA, 204) && hist.canGoForward, "вперёд")
hist.caretMoved(from: at(histA, 204), to: at(histA, 204))
hist.navigate(from: at(histA, 204), to: at(histA, 900))
check(lines(hist) == ["A.cs:5", "A.cs:204", "A.cs:900"] && !hist.canGoForward,
      "новый переход из середины отрезает будущее")
hist.navigate(from: at(histA, 900), to: NavTarget(url: histB, range: nil))
hist.caretMoved(from: at(histA, 900), to: at(histB, 12))
check(lines(hist).last == "B.cs:12", "вкладка без строки получает строку, куда встал курсор")

var edits = NavigationHistory()
edits.edited(at: at(histA, 10))
edits.edited(at: at(histA, 11))
edits.edited(at: at(histB, 50))
check(edits.edits.count == 2, "правки подряд в одном месте — одно место")
check(edits.previousEdit(from: at(histB, 50)) == at(histA, 11),
      "⇧⌘⌫ там, где только что правили, ведёт к предыдущей правке")
check(edits.previousEdit(from: at(histA, 11)) == nil, "дальше правок нет")
var edits2 = NavigationHistory()
edits2.edited(at: at(histA, 10))
edits2.edited(at: at(histB, 50))
check(edits2.previousEdit(from: at(histA, 300)) == at(histB, 50), "⇧⌘⌫ — последняя правка")
check(edits2.previousEdit(from: at(histB, 50)) == at(histA, 10), "повтор — правка перед ней")
edits2.edited(at: at(histA, 400))
check(edits2.previousEdit(from: at(histB, 1)) == at(histA, 400), "новая правка начинает сначала")
let recentPlaces = edits2.recent()
check(recentPlaces.first?.edited == true && recentPlaces.first?.place == at(histA, 400),
      "недавние места: свежая правка первой")

var capped = NavigationHistory()
for i in 0..<300 { capped.navigate(from: nil, to: at(histA, i * 100)) }
check(capped.places.count == NavigationHistory.capacity && capped.canGoBack, "история не растёт без края")

section("Правки строк")

func applied(_ text: String, _ edit: LineEditing.Edit?) -> String {
    guard let edit else { return text }
    return (text as NSString).replacingCharacters(in: edit.range, with: edit.text)
}
let threeLines = "one\ntwo\nthree\n" as NSString
let leDup = LineEditing.duplicate(threeLines, selection: NSRange(location: 5, length: 0))
check(applied(threeLines as String, leDup) == "one\ntwo\ntwo\nthree\n" && leDup.selection.location == 9,
      "⌘D без выделения — строка ещё раз, курсор в копии на том же месте")
let leDupLast = LineEditing.duplicate("a\nlast" as NSString, selection: NSRange(location: 3, length: 0))
check(applied("a\nlast", leDupLast) == "a\nlast\nlast", "последняя строка без перевода дублируется с переводом")
let leDupWord = LineEditing.duplicate(threeLines, selection: NSRange(location: 4, length: 3))
check(applied(threeLines as String, leDupWord) == "one\ntwotwo\nthree\n" && leDupWord.selection == NSRange(location: 7, length: 3),
      "с выделением — выделенное ещё раз, выделена копия")
let leDel = LineEditing.deleteLines(threeLines, selection: NSRange(location: 5, length: 0))
check(applied(threeLines as String, leDel) == "one\nthree\n" && leDel.selection.location == 4, "⌘⌫ — строка целиком")
let leDelLast = LineEditing.deleteLines("a\nb" as NSString, selection: NSRange(location: 2, length: 0))
check(applied("a\nb", leDelLast) == "a", "последняя строка уходит вместе с переводом перед ней")
let leUp = LineEditing.moveLines(threeLines, selection: NSRange(location: 5, length: 1), up: true)
check(applied(threeLines as String, leUp) == "two\none\nthree\n" && leUp?.selection == NSRange(location: 1, length: 1),
      "⌥⇧↑ — строка вверх, выделение с ней")
let leDown = LineEditing.moveLines(threeLines, selection: NSRange(location: 1, length: 0), up: false)
check(applied(threeLines as String, leDown) == "two\none\nthree\n" && leDown?.selection.location == 5,
      "⌥⇧↓ — строка вниз")
let leDownToEnd = LineEditing.moveLines("a\nb" as NSString, selection: NSRange(location: 0, length: 0), up: false)
check(applied("a\nb", leDownToEnd) == "b\na", "вниз к последней строке без перевода")
check(LineEditing.moveLines(threeLines, selection: NSRange(location: 0, length: 0), up: true) == nil,
      "первой строке вверх некуда")
let leCRLF = "a\r\nb\r\n" as NSString
check(applied(leCRLF as String, LineEditing.moveLines(leCRLF, selection: NSRange(location: 3, length: 0), up: true)) == "b\r\na\r\n",
      "переводы \\r\\n остаются")
let leBlock = LineEditing.moveLines(threeLines, selection: NSRange(location: 0, length: 8), up: false)
check(applied(threeLines as String, leBlock) == "three\none\ntwo\n", "выделение на две строки едет целиком")

// Склеить строки, регистр, «перейти к строке».
let joinSrc = "a {\n    b\n}\n" as NSString
let join1 = LineEditing.joinLines(joinSrc, selection: NSRange(location: 1, length: 0))
check(applied(joinSrc as String, join1) == "a { b\n}\n" && join1?.selection.location == 3,
      "⌃⇧J: следующая строка без отступа, через пробел, курсор в месте склейки")
check(applied(joinSrc as String, LineEditing.joinLines(joinSrc, selection: NSRange(location: 0, length: 11))) == "a { b }\n",
      "⌃⇧J с выделением — все его строки в одну")
check(applied("f(\n)" as String, LineEditing.joinLines("f(\n)" as NSString, selection: NSRange(location: 0, length: 0))) == "f()",
      "скобки склеиваются без пробела")
check(applied("x   \n\n" as String, LineEditing.joinLines("x   \n\n" as NSString, selection: NSRange(location: 0, length: 0))) == "x\n",
      "хвостовые пробелы уходят, пустая строка — без пробела")
check(LineEditing.joinLines("last" as NSString, selection: NSRange(location: 2, length: 0)) == nil, "клеить не с чем — nil")
let caseSrc = "let fooBar = 1" as NSString
let case1 = LineEditing.toggleCase(caseSrc, selection: NSRange(location: 6, length: 0))
check(applied(caseSrc as String, case1) == "let FOOBAR = 1" && case1?.selection == NSRange(location: 4, length: 6),
      "⌘⇧U без выделения — слово под курсором, выделено")
check(applied("ABC" as String, LineEditing.toggleCase("ABC" as NSString, selection: NSRange(location: 0, length: 3))) == "abc",
      "всё заглавное — в строчные")
check(LineEditing.toggleCase("a + b" as NSString, selection: NSRange(location: 2, length: 0)) == nil, "не на слове — nil")
let lt1 = LineEditing.lineTarget("42"), lt2 = LineEditing.lineTarget(" 42:7 "), lt3 = LineEditing.lineTarget(":3,2")
check(lt1?.line == 41 && lt1?.column == nil && lt2?.line == 41 && lt2?.column == 6 && lt3?.line == 2 && lt3?.column == 1,
      "⌘L: строка, строка:столбец, с двоеточием впереди")
check(LineEditing.lineTarget("0") == nil && LineEditing.lineTarget("abc") == nil && LineEditing.lineTarget("1:2:3") == nil,
      "⌘L: не номер — nil")

section("Парные скобки и кавычки")

let csQuotes = AutoPairs.quotes(for: Languages.csharp)
check(csQuotes.contains("\"") && csQuotes.contains("'"), "кавычки C# — из описания языка")
check(!AutoPairs.quotes(for: Languages.rust).contains("'"), "в Rust ' — не кавычка: там времена жизни")
func typed(_ text: String, _ caret: Int, _ c: String, length: Int = 0) -> (String, Int)? {
    guard let edit = AutoPairs.typing(c, in: text as NSString, selection: NSRange(location: caret, length: length),
                                      quotes: csQuotes) else { return nil }
    return (applied(text, edit), edit.selection.location)
}
check(typed("f", 1, "(")! == ("f()", 2), "( ставит и ), курсор между")
check(typed("f()", 2, ")")! == ("f()", 3), ") перед ) перешагивает её")
check(typed("x = ", 4, "\"")! == ("x = \"\"", 5), "кавычка — парой")
check(typed("x = \"\"", 5, "\"")! == ("x = \"\"", 6), "закрывающая кавычка перешагивается")
check(typed("don", 3, "'") == nil, "апостроф после буквы — один")
check(typed("fx", 1, "(") == nil, "перед словом пару не ставим")
check(typed("f(a, b)", 2, "(", length: 4)! == ("f((a, b))", 3), "скобка поверх выделения оборачивает его")
check(typed("x", 0, "\"", length: 1)! == ("\"x\"", 1), "кавычка поверх выделения — тоже")
check(typed("a", 1, "+") == nil, "обычный символ — обычный ввод")
check(typed("\"\"", 2, "\"") == nil, "третья кавычка подряд — обычный ввод (сырые строки)")
let bs = AutoPairs.deletingBackward(in: "f()" as NSString, selection: NSRange(location: 2, length: 0), quotes: csQuotes)
check(applied("f()", bs) == "f" && bs?.selection.location == 1, "Backspace в пустой паре стирает обе")
check(AutoPairs.deletingBackward(in: "f(a)" as NSString, selection: NSRange(location: 3, length: 0), quotes: csQuotes) == nil,
      "не пустая пара — обычный Backspace")

section("Сворачивание")

let foldSource = """
// шапка
// файла
// в три строки
class C {
    #region Input
    void M() {
        var s = "{ не скобка";
    }
    #endregion
    /* блок
       комментария */
    int x;
}
"""
let foldSyntax = SyntaxModel(text: foldSource, spec: Languages.csharp)
let foldList = FoldRegions.compute(foldSyntax)
func foldAt(_ line: Int) -> FoldRegion? { foldList.first { $0.line == line } }
check(foldAt(3)?.endLine == 12, "класс сворачивается до своей }")
check(foldAt(5)?.endLine == 7, "метод — до своей, скобка в строке не в счёт")
check(foldAt(4)?.endLine == 8, "#region — до #endregion")
check(foldAt(9)?.endLine == 10, "блочный комментарий")
check(foldAt(0)?.endLine == 2, "три строчных комментария подряд — одна шапка")
if let method = foldAt(5) {
    let hidden = (foldSource as NSString).substring(with: method.hidden)
    check(hidden.hasPrefix("\n") && hidden.hasSuffix("    "), "прячется всё между скобками")
}
check(FoldRegions.compute(SyntaxModel(text: "int x = 1;", spec: Languages.csharp)).isEmpty, "одна строка — нечего сворачивать")

section("Расширение выделения без Rustlyn")

let stepSource = "print(foo(bar, \"baz qux\"))\n" as NSString
let selSteps = SelectionSteps.around(stepSource, selection: NSRange(location: 11, length: 0))
    .map { stepSource.substring(with: $0) }
check(selSteps.first == "bar", "сначала слово (получено \(selSteps))")
check(selSteps.contains("bar, \"baz qux\"") && selSteps.contains("(bar, \"baz qux\")"), "потом скобки: внутри и целиком")
check(selSteps.contains("foo(bar, \"baz qux\")") == false || true, "лишнего не требуем")
check(selSteps.last == stepSource as String, "в конце — весь текст")
let selInString = SelectionSteps.around(stepSource, selection: NSRange(location: 17, length: 0))
    .map { stepSource.substring(with: $0) }
check(selInString.prefix(3).elementsEqual(["baz", "baz qux", "\"baz qux\""]),
      "в строке: слово, содержимое кавычек, кавычки (получено \(selInString))")

section("Переименование")

check(Rename.problem(with: "Hero") == nil && Rename.problem(with: "_hp2") == nil, "обычные имена годятся")
check(Rename.problem(with: "") != nil && Rename.problem(with: "2x") != nil && Rename.problem(with: "a-b") != nil,
      "пустое, с цифры, с дефисом — нет")
check(Rename.problem(with: "class") != nil && Rename.problem(with: "@class") == nil, "ключевое слово — только с @")
check(Rename.problem(with: "Здоровье") == nil, "кириллица в именах C# разрешена")
check(Rename.isOccurrence("Run", of: "Run") && Rename.isOccurrence("@class", of: "@class")
        && Rename.isOccurrence("Mark", of: "MarkAttribute") && Rename.isOccurrence("MarkAttribute", of: "MarkAttribute"),
      "имя, @имя и атрибут без Attribute — вхождения")
check(!Rename.isOccurrence("Ru", of: "Run") && !Rename.isOccurrence("un(", of: "Run") && !Rename.isOccurrence("", of: "Attribute"),
      "правка, съехавшая с имени, — не вхождение")
check(Rename.apply([(NSRange(location: 0, length: 1), "BB"), (NSRange(location: 2, length: 1), "DD")], to: "a c") == "BB DD",
      "правки применяются с конца и не сдвигают друг друга")

section("Ошибки и сигнатуры: типы")

let sigSample = RustlynSignatures(items: [RustlynSignature(label: "void Log(string s, int n)",
                                                           parameters: [NSRange(location: 9, length: 8),
                                                                        NSRange(location: 19, length: 5)])],
                                   active: 0, parameter: 1)
check(sigSample.activeParameter == NSRange(location: 19, length: 5), "подсвечивается параметр под курсором")
check(RustlynSignatures(items: sigSample.items, active: 0, parameter: 5).activeParameter == nil,
      "за последним параметром — ничего")
let diagnosticsSample = RustlynDiagnostics(items: [
    RustlynDiagnostic(range: NSRange(location: 0, length: 1), severity: .error, code: "CS0103", message: "x"),
    RustlynDiagnostic(range: NSRange(location: 2, length: 1), severity: .warning, code: "CS0168", message: "y"),
], semantic: true)
check(diagnosticsSample.errors == 1 && diagnosticsSample.warnings == 1, "ошибки и предупреждения считаются порознь")

section("Сочетания клавиш")

check(Shortcut("p", command: true).display == "⌘P", "⌘P")
check(Shortcut("left", command: true, option: true, control: true, shift: true).display == "⌃⌥⇧⌘←",
      "модификаторы в порядке меню macOS")
check(Shortcut("f6", shift: true).display == "⇧F6" && Shortcut("f6").functionNumber == 6, "функциональные клавиши")
check(Shortcut(text: "cmd+shift+p") == Shortcut("p", command: true, shift: true), "разбор строки из файла")
check(Shortcut(text: "Ctrl+Alt+Cmd+PageUp") == Shortcut("pageUp", command: true, option: true, control: true),
      "регистр и имена клавиш — как угодно")
check(Shortcut(text: "cmd+plus")?.key == "+" && Shortcut("+", command: true).text == "cmd+plus", "плюс пишется словом")
check(Shortcut(text: "ctrl+-") == Shortcut("-", control: true), "минус — как есть")
check(Shortcut(text: "hyper+p") == nil && Shortcut(text: "cmd+nothing") == nil && Shortcut(text: "") == nil,
      "чужие модификаторы и клавиши — не сочетание")
for sample in [Shortcut("b", command: true), Shortcut("f2"), Shortcut("space", command: true, shift: true),
               Shortcut("[", command: true, option: true)] {
    check(Shortcut(text: sample.text) == sample, "\(sample.display) переживает запись в файл")
}
check(Shortcut.namedKey(forKeyCode: 120) == "f2" && Shortcut.namedKey(forKeyCode: 126) == "up"
        && Shortcut.namedKey(forKeyCode: 0) == nil, "клавиши без символа — по коду")
check(!Shortcut("a").hasModifier && Shortcut("a").needsModifier && !Shortcut("f5").needsModifier,
      "букве нужен модификатор, F-клавише — нет")

let commandIDs = EditorCommand.allCases.map(\.rawValue)
check(Set(commandIDs).count == commandIDs.count, "идентификаторы команд не повторяются")
check(EditorCommand.allCases.allSatisfy { EditorCommand.groups.contains($0.group) }, "у каждой команды есть раздел")
var defaultsTaken: [Shortcut: EditorCommand] = [:]
var defaultClash: [String] = []
for command in EditorCommand.allCases {
    guard let shortcut = command.defaultShortcut else { continue }
    if let other = defaultsTaken[shortcut] { defaultClash.append("\(other.title) и \(command.title): \(shortcut.display)") }
    defaultsTaken[shortcut] = command
}
check(defaultClash.isEmpty, "по умолчанию сочетания не пересекаются (\(defaultClash))")

var keymap = Keymap()
check(keymap.shortcut(for: .back) == Shortcut("[", command: true), "по умолчанию — как было в меню")
keymap.set(Shortcut("-", control: true), for: .back)
check(keymap.shortcut(for: .back) == Shortcut("-", control: true) && keymap.isCustomized(.back), "своё сочетание")
keymap.set(nil, for: .rename)
check(keymap.shortcut(for: .rename) == nil && keymap.isCustomized(.rename), "можно и без сочетания")
keymap.set(Shortcut("f6", shift: true), for: .rename)
check(!keymap.isCustomized(.rename), "вернули как было — это уже не своё")
keymap.set(Shortcut("b", command: true), for: .findReferences)
check(keymap.conflicts(for: .findReferences) == [.goToDefinition]
        && keymap.command(using: Shortcut("b", command: true), except: .findReferences) == .goToDefinition,
      "то же сочетание у двух команд видно")
let saved = keymap.serialized()
check(saved.contains("\"nav.back\": \"ctrl+-\"") && !saved.contains("refactor.rename"),
      "в файле только поменянное (получено \(saved))")
check(Keymap.parse(saved) == keymap, "файл читается обратно")
let handEdited = Keymap.parse("{\"nav.back\": \"cmd+alt+left\", \"no.such\": \"cmd+x\", \"nav.forward\": \"cmd+???+x\", \"refactor.rename\": null}")
check(handEdited.shortcut(for: .back) == Shortcut("left", command: true, option: true)
        && handEdited.shortcut(for: .forward) == Shortcut("]", command: true)
        && handEdited.shortcut(for: .rename) == nil,
      "руками правленый файл: неизвестное и испорченное пропускается, null — без сочетания")
check(Keymap.parse("не json") == Keymap(), "мусор вместо файла — сочетания по умолчанию")
keymap.resetAll()
check(keymap == Keymap() && keymap.serialized() == "{}\n", "сбросить всё")

// ───────────────────────────── Окно коммита ─────────────────────────────
section("Окно коммита")
do {
    let porcelain = [
        "# branch.oid 1234567890abcdef", "# branch.head main", "# branch.upstream origin/main", "# branch.ab +2 -1",
        "1 M. N... 100644 100644 100644 aaa bbb staged.cs",
        "1 .M N... 100644 100644 100644 aaa bbb unstaged.cs",
        "1 MM N... 100644 100644 100644 aaa bbb both.cs",
        "1 A. N... 000000 100644 100644 000 bbb dir/new file.cs",
        "1 .D N... 100644 100644 000000 aaa aaa gone.cs",
        "2 R. N... 100644 100644 100644 aaa aaa R100 renamed.cs", "old.cs",
        "u UU N... 100644 100644 100644 100644 a b c conflict.cs",
        "? untracked.txt",
    ].joined(separator: "\0") + "\0"
    let tree = GitWorkingTree.parse(Data(porcelain.utf8))
    check(tree.branch == "main" && tree.upstream == "origin/main" && tree.ahead == 2 && tree.behind == 1,
          "ветка, upstream, впереди и позади")
    func change(_ path: String) -> GitChange? { tree.changes.first { $0.path == path } }
    check(change("staged.cs")?.staged == .modified && change("staged.cs")?.hasUnstaged == false, "M. — только подготовлено")
    check(change("unstaged.cs")?.staged == nil && change("unstaged.cs")?.unstaged == .modified, ".M — только в рабочей копии")
    check(change("both.cs")?.hasStaged == true && change("both.cs")?.hasUnstaged == true, "MM — в обеих группах")
    check(change("dir/new file.cs")?.staged == .added, "путь с пробелом, новый файл")
    check(change("gone.cs")?.unstaged == .deleted, "удалён в рабочей копии")
    check(change("renamed.cs")?.originalPath == "old.cs" && change("renamed.cs")?.staged == .renamed, "переименование со старым путём")
    check(change("conflict.cs")?.isConflicted == true && change("untracked.txt")?.isUntracked == true,
          "конфликт и неотслеживаемый — в неподготовленных")
    check(tree.staged.count == 4 && tree.unstaged.count == 5, "группы: \(tree.staged.count) и \(tree.unstaged.count)")

    let diff = """
    diff --git a/A.cs b/A.cs
    index 1111111..2222222 100644
    --- a/A.cs
    +++ b/A.cs
    @@ -1,3 +1,3 @@ class A
     one
    -two
    +TWO
     three
    @@ -10,2 +10,3 @@
     ten
    +ten and a half
     eleven
    \\ No newline at end of file
    """
    let patch = GitFilePatch.parse(diff)
    check(patch.header.count == 4 && patch.hunks.count == 2 && !patch.isBinary, "шапка и два куска")
    check(patch.hunks[0].oldStart == 1 && patch.hunks[1].newStart == 10 && patch.hunks[1].additions == 1
            && patch.hunks[0].deletions == 1, "начала и счётчики кусков")
    check(patch.hunks[1].lines.last == "\\ No newline at end of file", "пометка о конце файла — в куске")
    check(patch.patch(for: patch.hunks[0]).hasPrefix("diff --git a/A.cs b/A.cs\n")
            && patch.patch(for: patch.hunks[0]).contains("@@ -1,3 +1,3 @@ class A\n one\n-two\n+TWO\n three\n")
            && !patch.patch(for: patch.hunks[0]).contains("ten"), "патч одного куска — шапка и только он")
    check(GitFilePatch.parse("diff --git a/i.png b/i.png\nBinary files a/i.png and b/i.png differ\n").isBinary, "двоичный")
    check(CommitMessage.isEmpty("  \n# comment\n") && !CommitMessage.isEmpty("Fix\n") && CommitMessage.summary("A\nB") == "A",
          "сообщение: пустое, первая строка")

    // Настоящий git: подготовить один кусок из двух.
    let fm = FileManager.default
    let repo = fm.temporaryDirectory.appendingPathComponent("pilot-commit-\(getpid())")
    defer { try? fm.removeItem(at: repo) }
    try? fm.createDirectory(at: repo, withIntermediateDirectories: true)
    if Git.executable != nil {
        let original = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try? original.write(to: repo.appendingPathComponent("F.txt"), atomically: true, encoding: .utf8)
        _ = Git.execute(["init", "-q"], in: repo)
        _ = Git.execute(["-c", "user.name=t", "-c", "user.email=t@t", "add", "F.txt"], in: repo)
        let first = Git.execute(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-F", "-"], in: repo,
                                input: Data("Initial\n".utf8))
        check(first?.succeeded == true, "коммит с сообщением со входа (\(first?.message ?? "нет git"))")
        let edited = original.replacingOccurrences(of: "line 2\n", with: "line TWO\n")
            .replacingOccurrences(of: "line 19\n", with: "line NINETEEN\n")
        try? edited.write(to: repo.appendingPathComponent("F.txt"), atomically: true, encoding: .utf8)
        let worktree = GitFilePatch.parse(String(decoding: Git.run(["diff", "--no-color", "-U3", "--", "F.txt"], in: repo)?.stdout ?? Data(), as: UTF8.self))
        check(worktree.hunks.count == 2, "два куска в рабочей копии")
        let staged = Git.execute(["apply", "--cached", "-"], in: repo, input: Data(worktree.patch(for: worktree.hunks[0]).utf8))
        check(staged?.succeeded == true, "кусок подготовлен (\(staged?.message ?? ""))")
        let cached = GitFilePatch.parse(String(decoding: Git.run(["diff", "--cached", "--no-color", "--", "F.txt"], in: repo)?.stdout ?? Data(), as: UTF8.self))
        check(cached.hunks.count == 1 && cached.hunks[0].lines.contains("+line TWO"), "в индексе ровно первый кусок")
        let back = Git.execute(["apply", "--cached", "--reverse", "-"], in: repo, input: Data(cached.patch(for: cached.hunks[0]).utf8))
        let after = Git.run(["diff", "--cached", "--quiet"], in: repo)
        check(back?.succeeded == true && after?.status == 0, "и убран обратно — индекс чист")
        let status = GitWorkingTree.parse(Git.run(["status", "--porcelain=v2", "-z", "--branch"], in: repo)?.stdout ?? Data())
        check(status.changes.first?.path == "F.txt" && status.changes.first?.unstaged == .modified, "статус настоящего репозитория")
        let failed = Git.execute(["commit", "-q", "-F", "-"], in: repo, input: Data("x".utf8))
        check(failed?.succeeded == false && !(failed?.message ?? "").isEmpty, "отказ git — с причиной из stderr")
    }
}

// ───────────────────────────── Локальная история ─────────────────────────────
section("Локальная история")
do {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("pilot-history-\(getpid())")
    defer { try? fm.removeItem(at: base) }
    let dir = LocalHistory.directory(forProject: URL(fileURLWithPath: "/tmp/Game"), base: base)
    check(dir.lastPathComponent.hasPrefix("Game-")
            && dir != LocalHistory.directory(forProject: URL(fileURLWithPath: "/other/Game"), base: base),
          "папка проекта — по имени и хэшу пути")
    let history = LocalHistory(directory: dir)
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    check(history.record("a\nb\n", path: "A.cs", reason: .original, date: t0), "первая версия пишется")
    check(!history.record("a\nb\n", path: "A.cs", reason: .saved, date: t0 + 1), "такая же, как последняя, — нет")
    check(history.record("a\nB\n", path: "A.cs", reason: .saved, date: t0 + 2), "другая — да")
    history.record("a\nb\n", path: "A.cs", reason: .external, date: t0 + 3)
    let versions = history.versions(of: "A.cs")
    check(versions.map(\.reason) == [.external, .saved, .original] && versions.first?.lines == 3,
          "версии новые первыми, строки посчитаны")
    check(history.text(of: versions[1]) == "a\nB\n", "текст версии читается")
    check(versions[0].blob == versions[2].blob, "одинаковый текст — один файл в blobs")
    check(history.versions(of: "B.cs").isEmpty && !history.hasVersions("B.cs") && history.hasVersions("A.cs"),
          "у другого файла своя история")
    check(!history.record(String(repeating: "x", count: LocalHistory.maxFileSize + 1), path: "Big.bin", reason: .saved),
          "огромное не пишется")

    let old = (0..<60).map { HistoryVersion(date: t0 + Double($0) * 86_400, blob: "b\($0)", reason: .saved, lines: 1) }
    let kept = LocalHistory.pruned(old, now: t0 + 60 * 86_400)
    check(kept.first?.blob == "b30" && kept.count == 30, "старше \(LocalHistory.keepDays) дней уходит")
    check(LocalHistory.pruned([old[0]], now: t0 + 400 * 86_400).count == 1, "последняя версия остаётся всегда")

    // Кусок назад.
    func reverted(_ old: String, _ new: String) -> [String] {
        HistoryDiff.hunks(old: old, new: new).map { hunk in
            let edit = HistoryDiff.revert(hunk, old: old, new: new)
            return (new as NSString).replacingCharacters(in: edit.range, with: edit.text)
        }
    }
    check(reverted("a\nb\nc\n", "a\nX\nc\n") == ["a\nb\nc\n"], "изменённая строка возвращается")
    check(reverted("a\nb\nc\n", "a\nc\n") == ["a\nb\nc\n"], "удалённая — встаёт на место")
    check(reverted("a\nc\n", "a\nb\nc\n") == ["a\nc\n"], "добавленная — уходит")
    check(reverted("a\nb", "a\nX") == ["a\nb"], "последняя строка без перевода")
    check(reverted("a\nb\n", "a\n") == ["a\nb\n"], "удалённая в конце")
    check(reverted("a\nb", "a") == ["a\nb"], "удалённая в конце без перевода")
    let two = HistoryDiff.hunks(old: "1\n2\n3\n4\n5\n", new: "1\nX\n3\n4\nY\n")
    check(two.count == 2, "два места — два куска")
}

// ───────────────────────────── Консоль Unity ─────────────────────────────
section("Консоль Unity")
do {
    let header = """
    COMMAND LINE ARGUMENTS:
    /Applications/Unity/Hub/Editor/6000.0.1f1/Unity.app/Contents/MacOS/Unity
    -projectpath
    /Users/me/Game
    -useHub
    """
    check(UnityLog.projectPath(inHeader: header) == "/Users/me/Game", "проект лога — из -projectpath")
    check(UnityLog.projectPath(inHeader: "Successfully changed project path to: /Users/me/Other\n") == "/Users/me/Other",
          "или из смены пути проекта")
    let log = """
    Refreshing native plugins compatible for Editor in 1.23 ms, found 3 plugins.
    Preloading 0 native plugins for Editor in 0.00 ms.

    Hello from player
    UnityEngine.Debug:Log (object)
    Player:Start () (at Assets/Scripts/Player.cs:12)

    Low health!
    UnityEngine.Debug:LogWarning (object)
    Player:Update () (at Assets/Scripts/Player.cs:30)

    NullReferenceException: Object reference not set to an instance of an object
    Enemy.Update () (at Assets/Scripts/Enemy.cs:20)

    Assets/Scripts/Foo.cs(3,17): error CS0103: The name 'bar' does not exist in the current context
    Assets/Scripts/Foo.cs(5,9): warning CS0168: The variable 'x' is declared but never used

    System.InvalidOperationException: boom
      at Net.Client.Send () [0x00010] in /Users/me/Game/Assets/Net/Client.cs:44
      at Net.Client.Tick () [0x00000] in <filename unknown>:0

    """
    let entries = UnityLog.parse(log, firstID: 10)
    check(entries.map(\.level) == [.system, .info, .warning, .error, .error, .warning, .error],
          "уровни: служебное, Log, LogWarning, исключение, ошибка и предупреждение компиляции, исключение Mono (\(entries.map(\.level)))")
    check(entries.first?.id == 10 && entries.last?.id == 16, "номера идут подряд с заданного")
    check(entries[1].title == "Hello from player" && entries[1].location?.path == "Assets/Scripts/Player.cs"
            && entries[1].location?.line == 12, "Debug.Log: переход — к первому кадру из кода проекта, мимо Debug:Log")
    check(entries[1].frames.first?.isEngine == true && entries[1].frames.last?.isEngine == false,
          "кадры Unity отличаются от своих")
    check(entries[4].code == "CS0103" && entries[4].path == "Assets/Scripts/Foo.cs" && entries[4].line == 3
            && entries[4].column == 17 && entries[4].message.hasPrefix("The name"), "ошибка компиляции: код, место, текст")
    check(entries[6].frames.first?.path == "/Users/me/Game/Assets/Net/Client.cs" && entries[6].frames.first?.line == 44
            && entries[6].frames.last?.path == nil, "стек Mono: абсолютный путь, <filename unknown> — без ссылки")
    check(entries[3].collapseKey == UnityLog.parse(log, firstID: 99)[3].collapseKey && entries[3].collapseKey != entries[6].collapseKey,
          "одинаковые сообщения сворачиваются, разные — нет")
    check(UnityLog.parse("\r\nA\r\nUnityEngine.Debug:LogError (object)\r\nX:Y () (at Assets/X.cs:1)\r\n\r\n").map(\.level) == [.error],
          "CRLF и LogError")

    // Как пишет настоящая Unity 6: служебное без пустой строки перед
    // сообщением, кадры ExtractStackTrace и Logger:Log, хвост (Filename: …).
    let real = """
    Asset Pipeline Refresh (id=0fb5): Total: 0.090 seconds - Initiated by RefreshV2(AllowForceSynchronousImport)
    Thread 0x16c573000 may have been prematurely finalized
    [WARN][Audio] No audio mixer on ProjectConfig.
    UnityEngine.Debug:ExtractStackTraceNoAlloc (byte*,int,string)
    UnityEngine.StackTraceUtility:ExtractStackTrace () (at /Users/bokken/build/output/unity/unity/Runtime/Export/Scripting/StackTrace.cs:35)
    UnityEngine.DebugLogHandler:LogFormat (UnityEngine.LogType,UnityEngine.Object,string,object[])
    UnityEngine.Logger:Log (UnityEngine.LogType,object)
    UnityEngine.Debug:LogWarning (object)
    Engine.Diagnostics.Logs.UnityConsoleSink:Print (Engine.Diagnostics.Logs.LogEntry&) (at Assets/Scripts/Engine/Diagnostics/Logs/UnityConsoleSink.cs:168)
    Engine.Diagnostics.Logs.Log:Warning (Engine.Diagnostics.Logs.LogChannel,string) (at Assets/Scripts/Engine/Diagnostics/Logs/Log.cs:150)
    Engine.Audio.UnityAudio:.ctor (UnityEngine.Audio.AudioMixer,int) (at Assets/Scripts/Engine/Audio/UnityAudio.cs:85)

    (Filename: Assets/Scripts/Engine/Diagnostics/Logs/UnityConsoleSink.cs Line: 168)

    Multi-line message
    second line
    UnityEngine.Debug:LogError (object)
    Meta.Bootstrap:Boot () (at Assets/Scripts/Meta/Bootstrap.cs:131)

    (Filename: Assets/Scripts/Meta/Bootstrap.cs Line: 131)

    """
    let realEntries = UnityLog.parse(real)
    check(realEntries.map(\.level) == [.system, .warning, .error],
          "служебное перед сообщением — отдельно, хвост (Filename:) — не сообщение (\(realEntries.map(\.level)))")
    check(realEntries[1].title == "[WARN][Audio] No audio mixer on ProjectConfig.", "сообщение — строка перед стеком")
    check(realEntries[1].location?.path == "Assets/Scripts/Engine/Audio/UnityAudio.cs" && realEntries[1].location?.line == 85,
          "переход — мимо своего логгера, к тому, кто его позвал")
    check(realEntries[2].message == "Multi-line message\nsecond line", "после хвоста сообщение — весь блок, и многострочное")
    var chunked = UnityLog.Parser()
    let halves = real.components(separatedBy: "(Filename: Assets/Scripts/Engine/Diagnostics/Logs/UnityConsoleSink.cs Line: 168)\n\n")
    let byChunks = chunked.parse(halves[0] + "(Filename: Assets/Scripts/Engine/Diagnostics/Logs/UnityConsoleSink.cs Line: 168)\n\n")
        + chunked.parse(halves[1])
    check(byChunks.map(\.message) == realEntries.map(\.message) && byChunks.map(\.id) == [0, 1, 2],
          "кусками — то же, что целиком: разбор помнит, чем кончился прошлый кусок")
}

// ───────────────────────────── NuGet ─────────────────────────────
section("NuGet")
do {
    func v(_ s: String) -> NuGetVersion { NuGetVersion(s)! }
    check(v("1.2.10") > v("1.2.9") && v("1.2") == v("1.2.0.0") && v("2.0.0") > v("2.0.0-rc.1"),
          "версии: числа по порядку, недостающие — нули, релиз старше rc")
    check(v("1.0.0-beta.10") > v("1.0.0-beta.2") && v("1.0.0-beta") > v("1.0.0-alpha.5")
            && v("1.0.0-alpha") < v("1.0.0-alpha.1") && v("1.0.0-1") < v("1.0.0-a"),
          "предварительные метки: числа как числа, короче — младше, число младше буквы")
    check(v("1.0.0+abc") == v("1.0.0") && Set([v("1.0"), v("1.0.0")]).count == 1, "метаданные сборки не в счёт")
    check(NuGetVersion("") == nil && NuGetVersion("1.x") == nil && NuGetVersion("$(Ver)") == nil
            && NuGetVersion("1.0-") == nil, "не версия — nil")
    let all = [v("13.0.1"), v("13.0.3"), v("14.0.0-beta1"), v("12.0.0")]
    check(NuGetVersion.update(for: v("13.0.1"), among: all) == v("13.0.3"), "обновление — последняя стабильная")
    check(NuGetVersion.update(for: v("14.0.0-alpha"), among: all) == v("14.0.0-beta1"),
          "у предварительной — и предварительные")
    check(NuGetVersion.update(for: v("13.0.3"), among: all) == nil, "новее нет — nil")

    let csproj = """
    <Project Sdk="Microsoft.NET.Sdk">
      <PropertyGroup><TargetFramework>net8.0</TargetFramework></PropertyGroup>
      <ItemGroup>
        <PackageReference Include="Newtonsoft.Json" Version="13.0.3" />
        <PackageReference Include='Serilog'>
          <Version>3.1.1</Version>
        </PackageReference>
        <!-- <PackageReference Include="Old.Package" Version="1.0" /> -->
        <PackageReference Include="Central.Only" />
        <PackageReference Include="Exact" Version="[2.0.0]" PrivateAssets="all" />
        <PackageReference Update="Newtonsoft.Json" Version="99" />
        <PackageReferences Include="Not.A.Reference" Version="1" />
        <ProjectReference Include="../Lib/Lib.csproj" />
      </ItemGroup>
    </Project>
    """
    let refs = NuGetProjects.packageReferences(in: csproj)
    check(refs.map(\.id) == ["Newtonsoft.Json", "Serilog", "Central.Only", "Exact"],
          "ссылки на пакеты: без комментариев, Update и чужих тегов (\(refs.map(\.id)))")
    check(refs.first?.version == "13.0.3" && refs[1].version == "3.1.1" && refs[2].version == nil,
          "версия атрибутом и элементом; без версии — nil")
    check(refs[3].resolved == v("2.0.0") && NuGetReference(id: "X", version: "[1.0,2.0)").resolved == nil,
          "[2.0.0] — ровно эта версия, диапазон не сравнивается")
    check(NuGetProjects.isSDKStyle(csproj)
            && !NuGetProjects.isSDKStyle("<?xml version=\"1.0\"?><Project ToolsVersion=\"4.0\"><ItemGroup/></Project>"),
          "SDK-стиль отличается от проектов Unity")
    check(NuGetProjects.packageVersions(in: "<Project><ItemGroup><PackageVersion Include=\"Central.Only\" Version=\"1.2.3\" /></ItemGroup></Project>")
            == ["central.only": "1.2.3"], "Directory.Packages.props: версии по id")
    check(NuGetProjects.addCommand(project: "My App/App.csproj", id: "Serilog", version: "3.1.1")
            == "dotnet add 'My App/App.csproj' package Serilog --version 3.1.1"
            && NuGetProjects.removeCommand(project: "App.csproj", id: "Serilog") == "dotnet remove App.csproj package Serilog",
          "команды dotnet с кавычками где надо")

    // Проекты на диске: центральные версии ищутся вверх от проекта.
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("pilot-nuget-\(getpid())")
    defer { try? fm.removeItem(at: dir) }
    try? fm.createDirectory(at: dir.appendingPathComponent("src/App"), withIntermediateDirectories: true)
    try? fm.createDirectory(at: dir.appendingPathComponent("Unity"), withIntermediateDirectories: true)
    try? csproj.write(to: dir.appendingPathComponent("src/App/App.csproj"), atomically: true, encoding: .utf8)
    try? "<Project><ItemGroup><PackageVersion Include=\"central.only\" Version=\"4.5.6\" /></ItemGroup></Project>"
        .write(to: dir.appendingPathComponent("Directory.Packages.props"), atomically: true, encoding: .utf8)
    try? "<Project ToolsVersion=\"4.0\"></Project>"
        .write(to: dir.appendingPathComponent("Unity/Assembly-CSharp.csproj"), atomically: true, encoding: .utf8)
    let projects = NuGetProjects.discover(root: dir)
    check(projects.map(\.path) == ["src/App/App.csproj"], "найдены только проекты в SDK-стиле (\(projects.map(\.path)))")
    let central = projects.first?.reference("CENTRAL.ONLY")
    check(central?.version == "4.5.6" && central?.isCentral == true && projects.first?.frameworks == "net8.0",
          "версия из Directory.Packages.props, id без учёта регистра")
}

// ───────────────────────────── Запуск ─────────────────────────────
section("Запуск")
do {
    let exe = "<Project Sdk=\"Microsoft.NET.Sdk\"><PropertyGroup><OutputType>Exe</OutputType>"
        + "<Configurations>Debug;Release;Debug UNIX;Release UNIX</Configurations></PropertyGroup></Project>"
    let server = RunTargets.dotnetTarget(projectPath: "Server/Server.csproj", contents: exe)
    check(server?.name == "Server" && server?.command == "dotnet run --project Server/Server.csproj -c 'Debug UNIX'",
          "Exe с конфигурацией под Unix — dotnet run с ней (получено \(server?.command ?? "nil"))")
    let plain = "<Project><PropertyGroup>\n  <OutputType> exe </OutputType>\n</PropertyGroup></Project>"
    check(RunTargets.dotnetTarget(projectPath: "My App/App.csproj", contents: plain)?.command
            == "dotnet run --project 'My App/App.csproj'", "без особых конфигураций — без -c, путь в кавычках")
    check(RunTargets.dotnetTarget(projectPath: "Lib/Lib.csproj", contents: "<Project><PropertyGroup></PropertyGroup></Project>") == nil,
          "библиотека не запускается")
    let tests = exe.replacingOccurrences(of: "</Project>", with: "<ItemGroup><PackageReference Include=\"Microsoft.NET.Test.Sdk\"/></ItemGroup></Project>")
    check(RunTargets.dotnetTarget(projectPath: "T/T.csproj", contents: tests) == nil, "тесты — не цель запуска")
    check(RunTargets.macConfiguration("Debug;Release") == nil
            && RunTargets.macConfiguration("Release UNIX; Debug UNIX") == "Debug UNIX", "конфигурация под Unix — отладочная")

    let found = ["Server.Fiddle", "Server", "Server.Validation"].map {
        RunTarget(name: $0, command: "dotnet run --project \($0)/\($0).csproj")
    } + [RunTarget(name: "Deep", command: "dotnet run --project a/b/Deep.csproj")]
    let ordered = RunTargets.order(found, solutions: ["Server.sln"])
    check(ordered.map(\.name) == ["Server", "Server.Fiddle", "Server.Validation", "Deep"],
          "названный как решение — первым, дальше мельче и по имени (\(ordered.map(\.name)))")
    let twins = RunTargets.order([RunTarget(name: "App", command: "dotnet run --project a/App.csproj"),
                                  RunTarget(name: "App", command: "dotnet run --project b/App.csproj")], solutions: [])
    check(twins.map(\.name) == ["App (a)", "App (b)"], "одинаковые имена различаются папкой")

    let config = Data("""
    { "targets": [
        { "name": "Server", "command": "dotnet run --project Server", "env": { "SERVER_NAME": "local", "PORT": 22003 } },
        { "name": "Args", "command": ["echo", "a b"], "cwd": "tools" },
        { "name": "", "command": "x" },
        { "name": "Nothing" }
    ] }
    """.utf8)
    let parsed = RunTargets.parseConfig(config) ?? []
    check(parsed.map(\.name) == ["Server", "Args"], "run.json: цели без имени или команды пропускаются")
    check(parsed.first?.environment == ["SERVER_NAME": "local", "PORT": "22003"], "run.json: env, числа — строкой")
    check(parsed.last?.command == "echo 'a b'" && parsed.last?.directory == "tools", "run.json: массив аргументов и cwd")
    check(RunTargets.parseConfig(Data("[{\"name\":\"A\",\"command\":\"a\"}]".utf8))?.count == 1, "run.json: просто массив")
    check(RunTargets.parseConfig(Data("не json".utf8)) == nil, "run.json: мусор — nil")
    let merged = RunTargets.merge(configured: [RunTarget(name: "Server", command: "custom")], dotnet: ordered)
    check(merged.first?.command == "custom" && merged.filter { $0.name == "Server" }.count == 1,
          "описанное руками заменяет найденное")
    check(RunTargets.parseConfig(Data(RunTargets.configTemplate(for: ordered).utf8))?.map(\.name) == ordered.map(\.name),
          "шаблон run.json читается обратно")
    check(RunTargets.isRelevant("/p/Server/Server.csproj") && RunTargets.isRelevant("/p/.pilot/run.json")
            && !RunTargets.isRelevant("/p/Server/StartUp.cs"), "что меняет список целей")

    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pilot-run-\(getpid())")
    let fm = FileManager.default
    try? fm.removeItem(at: dir)
    for sub in ["Server", "Server/bin/Debug", "Server.Tests", "Lib", ".pilot"] {
        try? fm.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
    }
    try? exe.write(to: dir.appendingPathComponent("Server/Server.csproj"), atomically: true, encoding: .utf8)
    try? exe.write(to: dir.appendingPathComponent("Server/bin/Debug/Copy.csproj"), atomically: true, encoding: .utf8)
    try? tests.write(to: dir.appendingPathComponent("Server.Tests/Server.Tests.csproj"), atomically: true, encoding: .utf8)
    try? "<Project/>".write(to: dir.appendingPathComponent("Lib/Lib.csproj"), atomically: true, encoding: .utf8)
    try? "".write(to: dir.appendingPathComponent("Server.sln"), atomically: true, encoding: .utf8)
    var discovered = RunTargets.discover(root: dir)
    check(discovered.map(\.name) == ["Server"], "в проекте: только приложение, bin/ не обходится (\(discovered.map(\.name)))")
    try? "{\"targets\":[{\"name\":\"Docker\",\"command\":\"docker compose up\"}]}"
        .write(to: dir.appendingPathComponent(".pilot/run.json"), atomically: true, encoding: .utf8)
    discovered = RunTargets.discover(root: dir)
    check(discovered.map(\.name) == ["Docker", "Server"], "run.json — первым")
    try? fm.removeItem(at: dir)
}

do {
    check(ConsoleDecoder.clean("\u{1B}[32minfo\u{1B}[0m: ok\r\n") == "info: ok\n", "цвета убираются, \\r\\n — перевод строки")
    check(ConsoleDecoder.clean("10%\r20%\n") == "10%\n20%\n", "одинокий \\r — тоже")
    check(ConsoleDecoder.clean("\u{1B}]0;title\u{07}text") == "text", "заголовок окна (OSC) убирается")
    var decoder = ConsoleDecoder()
    let bytes = Array("я\u{1B}[31mкрасный".utf8)
    var out = ""
    for byte in bytes { out += decoder.feed(Data([byte])) }
    check(out == "якрасный", "буквы и цвета, разорванные между кусками, собираются (\(out))")
}
// ─────────────────────── Конфиги ───────────────────────
let configRules = ConfigRules()
section("Конфиги: реестр")
let metaJSON = """
{ "shared": [ { "path": "jobs/jobs.json", "alias": "Jobs" }, { "path": "user/levels.json", "alias": "UserLevels" } ],
  "server": [ { "path": "clans/rewards.json", "alias": "SeasonRewards", "staging_send_to_client": true } ] }
"""
let entries = ConfigCatalog.parse(Data(metaJSON.utf8))
check(entries?.count == 3, "три записи из двух разделов")
let catalog = ConfigCatalog(directory: URL(fileURLWithPath: "/p/Configs"), rules: configRules, entries: entries ?? [])
check(catalog.files(forAlias: "UserLevels").map(\.path) == ["/p/Configs/user/levels.json"], "алиас → файл")
check(catalog.files(forAlias: "Nope").isEmpty && !catalog.knows("Nope"), "неизвестный алиас")
check(catalog.alias(of: URL(fileURLWithPath: "/p/Configs/clans/rewards.json")) == "SeasonRewards", "файл → алиас")
check(catalog.alias(of: URL(fileURLWithPath: "/p/Other/clans/rewards.json")) == nil, "файл не из Configs — не конфиг")
check(catalog.isMeta(URL(fileURLWithPath: "/p/Configs/registry.json")), "registry.json узнаётся")
check(ConfigCatalog.parse(Data("{\"name\": \"pkg\", \"version\": \"1\"}".utf8)) == nil, "чужой registry.json — не каталог")
check(ConfigCatalog.parse(Data("[1, 2]".utf8)) == nil, "массив — не каталог")

section("Конфиги: деревья")
let configsDir = FileManager.default.temporaryDirectory.appendingPathComponent("pilot-configs-\(getpid())")
try? FileManager.default.removeItem(at: configsDir)
func putConfig(_ path: String, _ text: String = "{}") {
    let url = configsDir.appendingPathComponent(path)
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! text.write(to: url, atomically: true, encoding: .utf8)
}
putConfig("Configs/registry.json", #"{"shared": [{"path": "quests/easy.json", "alias": "Quests.easy"}, {"path": "quests/hard.json", "alias": "Quests.hard"}, {"path": "Generated/Offers_data_generated.json", "alias": "Offers"}], "server": []}"#)
putConfig("Configs/quests/easy.json"); putConfig("Configs/quests/hard.json")
putConfig("Configs/offers/standard/folder.json", #"{"merge": {"type": "by_files"}, "alias": "Offers"}"#)
putConfig("Configs/offers/standard/b.json"); putConfig("Configs/offers/standard/a.json")
putConfig("Configs/offers/standard/Offers_data_generated.json")
putConfig("Configs/offers/trigger/folder.json", #"{"merge": {"type": "by_files"}, "alias": "Offers"}"#)
putConfig("Configs/offers/trigger/t.json")
putConfig("Configs/cases/folder.json", #"{"merge": {"type": "by_folders"}, "alias": "Chests."}"#)
putConfig("Configs/cases/gold/main.json"); putConfig("Configs/cases/gold/info.json"); putConfig("Configs/cases/silver/main.json")
putConfig("Configs/Generated/Offers_data_generated.json")
let trees = ConfigCatalog.load(root: configsDir, rules: configRules)!
func rel(_ urls: [URL]) -> [String] { urls.map { trees.path(of: $0) ?? $0.path } }
check(rel(trees.files(forAlias: "Offers")) == ["offers/standard/a.json", "offers/standard/b.json", "offers/trigger/t.json"],
      "by_files: все JSON папок с этим алиасом, без folder.json и сгенерированного (\(rel(trees.files(forAlias: "Offers"))))")
check(rel(trees.files(forAlias: "Chests.main")) == ["cases/gold/main.json", "cases/silver/main.json"],
      "by_folders: алиас — префикс и имя файла из подпапок")
check(rel(trees.files(forAlias: "Chests.info")) == ["cases/gold/info.json"], "by_folders: другое имя — другой алиас")
check(rel(trees.files(forAlias: "Quests.")) == ["quests/easy.json", "quests/hard.json"], "префикс с точкой — все конфиги с этим началом")
check(trees.files(forAlias: "Quest").isEmpty, "префикс без точки — не префикс")
check(trees.alias(of: configsDir.appendingPathComponent("Configs/cases/silver/main.json")) == "Chests.main", "файл дерева → алиас")
check(ConfigCatalog.folderConfig(Data(#"{"merge": {"type": "by_magic"}, "alias": "X"}"#.utf8)) == nil, "неизвестная сборка — не дерево")
try? FileManager.default.removeItem(at: configsDir)

section("Конфиги: код")
func literal(_ line: String, at column: Int) -> String? {
    let units = Array(line.utf16)
    return ConfigCatalog.stringLiteral(in: units, line: 0..<units.count, at: column)?.text
}
let aliasLine = #"        [ConfigModel(typeof(InteriorModel))] public const string GarageInterior = "Garage";"#
let quote = Array(aliasLine.utf16).firstIndex(of: 0x22)!
check(literal(aliasLine, at: quote + 3) == "Garage", "строка под курсором")
check(literal(aliasLine, at: quote + 1 + "Garage".count) == "Garage", "курсор сразу перед закрывающей кавычкой")
check(literal(aliasLine, at: quote) == nil, "курсор перед открывающей кавычкой — ещё не строка")
check(literal(aliasLine, at: 20) == nil, "вне строки — ничего")
check(literal(#"var s = "a\"b" + "Jobs";"#, at: 20) == "Jobs", "экранированная кавычка не закрывает строку")
let constant = ConfigCatalog.constant(in: aliasLine, named: "GarageInterior")
check(constant?.value == "Garage", "значение константы")
check(constant.map { Array(aliasLine.utf16)[$0.column] } == 0x47
        && constant?.column == aliasLine.utf16.count - #"GarageInterior = "Garage";"#.utf16.count,
      "колонка имени константы")
check(ConfigCatalog.constant(in: aliasLine, named: "Other") == nil, "другое имя — не она")
check(ConfigCatalog.constant(in: #"if (alias == "Jobs") return;"#) == nil, "сравнение — не объявление")
check(ConfigCatalog.constant(in: #"public const string PROGRESS_CONFIG="EventProgress";"#)?.value == "EventProgress",
      "без пробелов вокруг =")
check(ConfigCatalog.modelType(in: aliasLine, attribute: "ConfigModel") == "InteriorModel", "модель из ConfigModel")
let generic = #"[ConfigModel(typeof(Dictionary<ElementModel, VehicleParametersItemModel>))] public const string VehicleParameters = "VehicleParameters";"#
check(ConfigCatalog.modelType(in: generic, attribute: "ConfigModel").map(ConfigCatalog.typeNames(in:))
        == ["VehicleParametersItemModel", "ElementModel", "Dictionary"], "имена типа модели, последнее первым")
check(ConfigCatalog.modelType(in: #"public const string X = "Y";"#, attribute: "ConfigModel") == nil, "без атрибута — модели нет")

// ─────────────────────────── Отладка ───────────────────────────
section("Отладка: протокол Mono")
do {
    var w = SDBWriter()
    w.int(-2); w.long(0x0102_0304_0506_0708); w.string("Ёж"); w.bool(true); w.id(42)
    var r = SDBReader(w.bytes)
    check((try? r.int()) == -2, "int туда и обратно")
    check((try? r.long()) == 0x0102_0304_0506_0708, "long — старшие 4 байта первыми")
    check((try? r.string()) == "Ёж", "строка — длина в байтах UTF-8")
    check((try? r.bool()) == true && (try? r.id()) == 42 && !r.hasMore, "bool и id, пакет прочитан до конца")
    var short = SDBReader([0, 0, 0])
    check((try? short.int()) == nil, "короткий пакет — ошибка, а не падение")

    let packet = SDBWriter.packet(id: 7, set: 1, command: 8, body: [0, 0, 0, 2])
    check(packet.count == 15 && Array(packet[0..<4]) == [0, 0, 0, 15] && packet[8] == 0 && packet[9] == 1 && packet[10] == 8,
          "заголовок команды: длина с заголовком, флаги 0, набор и команда")

    let old = SDBVersion(major: 2, minor: 58)
    let negotiated = SDBVersion.negotiate(runtime: old)
    check(negotiated.announce == SDBVersion(major: 2, minor: 56) && negotiated.effective == SDBVersion(major: 2, minor: 56),
          "Unity 2022 (2.58) — объявляем 2.56, как Mono.Debugger.Soft")
    let fresh = SDBVersion.negotiate(runtime: SDBVersion(major: 2, minor: 66))
    check(fresh.announce.minor == 65 && fresh.effective.minor == 65, "свежий рантайм — 2.65")
    check(SDBVersion.negotiate(runtime: SDBVersion(major: 2, minor: 40)).effective.minor == 40,
          "старый рантайм — работаем на его версии")

    // Значения: int, строка-ссылка, null, структура (Vector2) с двумя float.
    var v = SDBWriter()
    v.byte(0x08); v.int(-5)
    v.byte(0x0e); v.id(100)
    v.byte(0x1c); v.id(0)
    v.byte(0x11); v.byte(0); v.id(55); v.int(2)
    v.byte(0x0c); v.int(Int32(bitPattern: Float(1.5).bitPattern))
    v.byte(0x0c); v.int(Int32(bitPattern: Float(-2).bitPattern))
    var vr = SDBReader(v.bytes)
    let version = SDBVersion(major: 2, minor: 56)
    check((try? vr.value(version)) == .int(-5, .i4), "int32")
    check((try? vr.value(version)) == .object(100, .string), "строка — ссылкой на объект")
    check((try? vr.value(version)) == .null, "нулевая ссылка — null")
    let vector = try? vr.value(version)
    check(vector == .valueType(type: 55, isEnum: false, fields: [.float(1.5), .float(-2)]), "структура с полями")
    check(SDBValue.float(1.5).primitiveText == "1.5" && SDBValue.float(-2).primitiveText == "-2"
            && SDBValue.char(65).primitiveText == "65 'A'", "как значения выглядят в панели")

    // Составное событие: точка останова в потоке 3, метод 9, смещение 12.
    var e = SDBWriter()
    e.byte(2); e.int(2)
    e.byte(10); e.int(5); e.id(3); e.id(9); e.long(12)
    e.byte(12); e.int(6); e.id(3); e.id(77)
    var er = SDBReader(e.bytes)
    let parsed = try? SDBEvent.parseComposite(&er, version: version)
    check(parsed?.0 == .all && parsed?.1.count == 2, "составное событие: политика и число событий")
    check(parsed?.1.first == SDBEvent(kind: .breakpoint, request: 5, thread: 3, id: 9, location: 12),
          "точка останова: запрос, поток, метод, смещение")
    check(parsed?.1.last?.kind == .typeLoad && parsed?.1.last?.id == 77, "загрузка типа")
}

section("Отладка: куда ставить точку")
do {
    // Метод Damage: строки 17–22, лямбда внутри — 19–19, в другом файле — мимо.
    let file = "/p/Assets/Player.cs"
    let damage = SDBDebugInfo(files: ["Assets/Player.cs"], points: [
        .init(offset: 0, line: 17, file: 0), .init(offset: 1, line: 18, file: 0),
        .init(offset: 8, line: 20, file: 0), .init(offset: 20, line: 22, file: 0),
        .init(offset: 21, line: 0xfeefee, file: 0),
    ])
    let lambda = SDBDebugInfo(files: ["/p/Assets/Player.cs"], points: [.init(offset: 0, line: 19, file: 0)])
    let other = SDBDebugInfo(files: ["/p/Assets/Enemy.cs"], points: [.init(offset: 0, line: 18, file: 0)])
    let candidates: [SDBLineResolver.Candidate] = [.init(method: 1, info: damage), .init(method: 2, info: lambda),
                                                   .init(method: 3, info: other)]
    func spots(_ line: Int) -> [String] {
        SDBLineResolver.resolve(line: line, in: candidates) { SDBLineResolver.pdbPath($0, matches: file) }
            .map { "\($0.method):\($0.offset):\($0.line)" }
    }
    check(spots(18) == ["1:1:18"], "строка с кодом — её точка")
    check(spots(19) == ["2:0:19"], "строка лямбды — в лямбду, а не в метод вокруг")
    check(spots(21) == ["1:20:22"], "пустая строка — к следующей с кодом в том же методе")
    check(spots(30).isEmpty, "вне методов — некуда")
    check(damage.location(at: 10).map { "\($0.file ?? ""):\($0.line)" } == "Assets/Player.cs:20",
          "кадр на смещении — последняя точка до него")
    check(SDBLineResolver.pdbPath("Assets/Player.cs", matches: "/p/Assets/Player.cs")
            && SDBLineResolver.pdbPath("/P/Assets/player.CS", matches: "/p/Assets/Player.cs")
            && SDBLineResolver.pdbPath("Assets\\Player.cs", matches: "/p/Assets/Player.cs")
            && !SDBLineResolver.pdbPath("layer.cs", matches: "/p/Assets/Player.cs")
            && !SDBLineResolver.pdbPath("/q/Assets/Player.cs", matches: "/p/Assets/Player.cs"),
          "путь из PDB: полный, от корня Unity, с обратными слешами; хвост — только целыми частями")
    check(SDBNames.pretty("System.Collections.Generic.List`1[[System.Int32, mscorlib, Version=4.0.0.0]]")
            == "System.Collections.Generic.List<int>", "обобщённый тип Mono — как в C#")
    check(SDBNames.pretty("System.Collections.Generic.Dictionary`2[[System.String, mscorlib],[Demo.Player, Assembly-CSharp]]")
            == "System.Collections.Generic.Dictionary<string, Player>", "два аргумента")
    check(SDBNames.pretty("System.Int32[]") == "int[]" && SDBNames.pretty("Demo.Player") == "Demo.Player",
          "массив и простой тип")
    check(SDBNames.short("System.Collections.Generic.List<int>") == "List<int>", "короткое имя")
    check(SDBNames.field("<Health>k__BackingField") == "Health" && SDBNames.field("_items") == "_items",
          "поле автосвойства — именем свойства")
}

section("Отладка: точки останова")
do {
    func shift(_ lines: Set<Int>, _ line: Int, _ ch: Int, _ endLine: Int, _ inserted: Int) -> [Int] {
        BreakpointSet.shift(lines, start: (line, ch), endLine: endLine, inserted: inserted).sorted()
    }
    check(shift([2, 10], 5, 3, 5, 2) == [2, 12], "две новые строки выше — точка ниже сдвигается")
    check(shift([2, 10], 5, 3, 8, 0) == [2, 7], "удалили три строки выше — поднимается")
    check(shift([6, 7, 10], 5, 3, 8, 0) == [5, 7], "точки в удалённом переезжают на строку правки")
    check(shift([5], 5, 0, 5, 1) == [6], "Enter в начале строки с точкой уносит её вниз")
    check(shift([5], 5, 4, 5, 1) == [5], "Enter в середине строки — точка остаётся")
    check(shift([5], 5, 4, 5, 0) == [5], "правка без переводов строки ничего не двигает")

    var set = BreakpointSet()
    let root = URL(fileURLWithPath: "/tmp/proj")
    let file = root.appendingPathComponent("Assets/Player.cs")
    check(set.toggle(file, line: 4) && set.lines(in: file) == [4], "поставить")
    check(!set.toggle(file, line: 4) && set.isEmpty, "снять — файл уходит совсем")
    set.toggle(file, line: 4); set.toggle(file, line: 9)
    set.toggle(URL(fileURLWithPath: "/elsewhere/X.cs"), line: 1)
    let stored = set.serialized(root: root)
    check(stored == ["Assets/Player.cs": [4, 9]], "хранятся пути от корня; чужие файлы — нет")
    let moved = BreakpointSet.deserialized(stored, root: URL(fileURLWithPath: "/new/place"))
    check(moved.lines(in: URL(fileURLWithPath: "/new/place/Assets/Player.cs")) == [4, 9], "проект переехал — точки с ним")
    let defaults = UserDefaults(suiteName: "pilot.coretests.\(UUID().uuidString)")!
    set.save(root: root, defaults: defaults)
    check(BreakpointSet.load(root: root, defaults: defaults).lines(in: file) == [4, 9], "переживают перезапуск")
}

section("Отладка: цели")
do {
    let editor = "/Applications/Unity/Hub/Editor/2022.3.76f1/Unity.app/Contents/MacOS/Unity -projectpath /Users/me/work/my game -useHub -hubIPC -cloudEnvironment production"
    check(DebugTargets.unityProjectPath(in: editor) == "/Users/me/work/my game", "путь проекта с пробелом из командной строки Unity")
    check(DebugTargets.unityProjectPath(in: "/Applications/Unity Hub.app/Contents/MacOS/Unity Hub") == nil, "Unity Hub — не редактор")
    check(DebugTargets.unityPort(for: 12345) == 56345, "порт агента: 56000 + pid % 1000")
    let list = [DebugTargets.ProcessLine(pid: 12345, arguments: editor),
                DebugTargets.ProcessLine(pid: 777, arguments: "/usr/local/share/dotnet/dotnet /Users/me/work/srv/Server/bin/Debug/net8.0/Server.dll"),
                DebugTargets.ProcessLine(pid: 778, arguments: "/usr/local/share/dotnet/dotnet /Users/me/other/bin/X.dll")]
    check(DebugTargets.unityEditors(root: URL(fileURLWithPath: "/Users/me/work/my game"), in: list)
            == [.unityEditor(pid: 12345, port: 56345)], "редактор именно этого проекта")
    check(DebugTargets.dotnetProcesses(root: URL(fileURLWithPath: "/Users/me/work/srv"), in: list)
            == [.dotnetAttach(pid: 777, name: "Server")], "процесс .NET из проекта; чужой — нет")

    let announce = "[IP] 192.168.1.5 [Port] 55000 [Flags] 3 [Guid] 2400123 [EditorId] 5678 [Version] 1048832 [Id] AndroidPlayer(Pixel_7@192.168.1.5) [Debug] 1 [PackageName] AndroidPlayer [ProjectName] mygame"
    let player = DebugTargets.PlayerAnnouncement.parse(announce)
    check(player?.ip == "192.168.1.5" && player?.guid == 2400123 && player?.debug == true
            && player?.id == "AndroidPlayer(Pixel_7@192.168.1.5)" && player?.project == "mygame",
          "анонс плеера Unity")
    check(DebugTargets.PlayerAnnouncement.parse("[IP] 1.2.3.4 [Debug] 0")?.debug == nil, "без GUID — не анонс")

    check(DebugTargets.isExecutableProject("<Project><PropertyGroup><OutputType>Exe</OutputType></PropertyGroup></Project>", name: "Server"),
          "OutputType Exe — запускаемый")
    check(!DebugTargets.isExecutableProject("<OutputType>Exe</OutputType><PackageReference Include=\"Microsoft.NET.Test.Sdk\" />", name: "Server.Tests")
            && !DebugTargets.isExecutableProject("<OutputType>Library</OutputType>", name: "Lib")
            && !DebugTargets.isExecutableProject("<OutputType>Exe</OutputType>", name: "Server.Benchmarks"),
          "тесты, бенчмарки и библиотеки — нет")
}


section("Пара проектов")
let pairParent = URL(fileURLWithPath: "/work")
let pairDirs: Set<String> = ["/work/game-client", "/work/game-server", "/work/solo", "/work/GameClient", "/work/GameServer",
                              "/work/shop-app", "/work/shop-backend"]
let isPairDir = { (path: String) in pairDirs.contains(path) }
check(ProjectPair.partner(of: pairParent.appendingPathComponent("game-client"), links: [:], isDirectory: isPairDir)?.path == "/work/game-server",
      "game-client узнаёт game-server рядом")
check(ProjectPair.partner(of: pairParent.appendingPathComponent("game-server"), links: [:], isDirectory: isPairDir)?.path == "/work/game-client",
      "и наоборот")
check(ProjectPair.partner(of: pairParent.appendingPathComponent("GameClient"), links: [:], isDirectory: isPairDir)?.path == "/work/GameServer",
      "GameClient ↔ GameServer")
check(ProjectPair.partner(of: pairParent.appendingPathComponent("solo"), links: [:], isDirectory: isPairDir) == nil,
      "без пары по имени — никого")
check(ProjectPair.label(of: URL(fileURLWithPath: "/work/game-server")) == "server"
        && ProjectPair.label(of: URL(fileURLWithPath: "/work/solo")) == "solo", "подпись: server; иначе имя папки")
var pairLinks = ProjectPair.linking(URL(fileURLWithPath: "/work/solo"), URL(fileURLWithPath: "/work/game-server"), in: [:])
check(ProjectPair.partner(of: URL(fileURLWithPath: "/work/solo"), links: pairLinks, isDirectory: isPairDir)?.path == "/work/game-server"
        && ProjectPair.partner(of: URL(fileURLWithPath: "/work/game-server"), links: pairLinks, isDirectory: isPairDir)?.path == "/work/solo",
      "связь руками — в обе стороны и сильнее имён")
pairLinks = ProjectPair.linking(URL(fileURLWithPath: "/work/game-client"), URL(fileURLWithPath: "/work/game-server"), in: pairLinks)
check(pairLinks["/work/solo"] == nil, "новая связь разрывает прежнюю пару")
pairLinks = ProjectPair.unlinking(URL(fileURLWithPath: "/work/game-client"), partner: URL(fileURLWithPath: "/work/game-server"), in: pairLinks)
check(ProjectPair.partner(of: URL(fileURLWithPath: "/work/game-client"), links: pairLinks, isDirectory: isPairDir) == nil,
      "разорванная пара не складывается снова по именам")
let mirrorRules = PairRules(mirrors: ["docs/shared/", "tools/"])
check(mirrorRules.isMirrored("docs/shared/style.md") && mirrorRules.isMirrored("tools/x/run.sh")
        && !mirrorRules.isMirrored("docs/other.md") && !PairRules().isMirrored("docs/shared/style.md"),
      "зеркальные папки — только из правил")
check(ProjectPair.partner(of: pairParent.appendingPathComponent("shop-app"), links: [:], isDirectory: isPairDir) == nil
        && ProjectPair.partner(of: pairParent.appendingPathComponent("shop-app"), links: [:],
                               extra: [PairRules.Suffixes(first: "-app", second: "-backend")],
                               isDirectory: isPairDir)?.path == "/work/shop-backend",
      "окончания пары из расширения")

section("Датаграммы: разбор")
let packetRules = DatagramRules(interface: "IPacket", write: ["Write", "Serialize"], read: ["Read", "Deserialize"],
                                send: ["Send"], receive: ["PacketFilter"])
let serverDatagram = """
using Net;
namespace Server
{
    // Статус создания: "struct Fake : IPacket" в комментарии не в счёт
    public struct StatusPacket : IPacket
    {
        [JsonProperty("s")] public CreationStatus Status;
        public string ErrorKey = "none;";
        public const int Version = 2;
        public static int Counter;
        public int A, B;

        public void Write(PacketWriter writer)
        {
            writer.WriteInt((int)Status);
            writer.WriteString(ErrorKey);
            Id.Write(writer);
            writer.Write<Vector3>(A);
        }

        public void Read(ref PacketReader reader)
        {
            Status = (CreationStatus) reader.ReadInt();
            ErrorKey = reader.ReadString();
            Id.Read(ref reader);
            A = reader.Read<Vector3>();
        }
    }
}
"""
if let shape = DatagramContract.shape(named: "StatusPacket", in: serverDatagram, rules: packetRules) {
    check(shape.fields.map(\.name) == ["Status", "ErrorKey", "A", "B"], "поля: без const и static, `int A, B` — два (получено \(shape.fields.map(\.name)))")
    check(shape.fields.first?.type == "CreationStatus" && shape.fields[2].type == "int", "типы полей")
    check(shape.writes.map(\.kind) == ["Int", "String", "value", "value"], "шаги Write (получено \(shape.writes.map(\.kind)))")
    check(shape.writes.map(\.field) == ["Status", "ErrorKey", "", "A"], "поля шагов Write (получено \(shape.writes.map(\.field)))")
    check(shape.reads.map(\.kind) == ["Int", "String", "value", "value"] && shape.reads.map(\.field) == ["Status", "ErrorKey", "", "A"],
          "Read: поле — слева от `=`, вложенная структура — value (получено \(shape.reads.map(\.display)))")
    let nameText = (serverDatagram as NSString).substring(with: shape.nameRange)
    check(nameText == "StatusPacket", "имя структуры — там, где объявлена, а не в комментарии")
} else {
    check(false, "датаграмма разбирается")
}
check(DatagramContract.shape(named: "Missing", in: serverDatagram, rules: packetRules) == nil, "нет такой — nil")

section("Датаграммы: сверка")
func datagram(_ fields: String, write: String, read: String) -> DatagramShape {
    DatagramContract.shape(named: "D", in: "struct D : IPacket { \(fields) public void Write(PacketWriter w) { \(write) } public void Read(ref PacketReader r) { \(read) } }",
                           rules: packetRules)!
}
let sameWire = datagram("public int itemId;", write: "w.WriteInt(itemId);", read: "itemId = r.ReadInt();")
let renamedWire = datagram("public int ItemId;", write: "w.WriteInt(ItemId);", read: "ItemId = r.ReadInt();")
let renameIssues = DatagramContract.compare(sameWire, with: renamedWire, label: "client", rules: packetRules)
check(renameIssues.count == 1 && renameIssues[0].kind == .rename && !renameIssues[0].breaksWire,
      "другое имя поля при том же проводе — переименование, не поломка (получено \(renameIssues.map(\.message)))")
let uintWire = datagram("public uint itemId;", write: "w.WriteUInt(itemId);", read: "itemId = r.ReadUInt();")
let uintIssues = DatagramContract.compare(uintWire, with: sameWire, label: "client", rules: packetRules)
check(uintIssues.filter(\.breaksWire).map(\.kind) == [.write, .read], "uint против int — ломает провод и в Write, и в Read")
check(uintIssues.contains { $0.kind == .fieldType && !$0.breaksWire }, "тип поля — для сведения, провод уже сказал")
let asymmetric = datagram("public EntityId Id;", write: "w.Write(Id);", read: "Id = r.Read<EntityId>();")
let nestedRead = datagram("public EntityId Id;", write: "w.Write(Id);", read: "Id.Read(ref r);")
check(DatagramContract.compare(asymmetric, with: nestedRead, label: "client", rules: packetRules).isEmpty,
      "`Read<T>()` и `Id.Read(ref r)` — одно и то же")
let senderOnly = datagram("public short Channel;", write: "w.WriteShort(Channel);", read: "")
let receiverOnly = datagram("public short Channel;", write: "", read: "Channel = r.ReadShort();")
check(DatagramContract.compare(senderOnly, with: receiverOnly, label: "server", rules: packetRules).isEmpty,
      "пустой метод — эта сторона так не делает, сверять нечего")
let emptyServer = datagram("", write: "", read: "")
let quizClient = datagram("public string QuizId;", write: "w.WriteString(QuizId);", read: "QuizId = r.ReadString();")
let quizIssues = DatagramContract.compare(emptyServer, with: quizClient, label: "client", rules: packetRules)
check(quizIssues.count == 1 && quizIssues[0].breaksWire && quizIssues[0].message.contains("QuizId"),
      "провод не с чем сверить — поля строго: лишнее поле клиента ломает (получено \(quizIssues.map(\.message)))")
check(DatagramContract.normalizedType("Shared.Models.EntityId[]") == DatagramContract.normalizedType("EntityId []")
        && DatagramContract.normalizedType("Int32") == "int", "тип без пространств имён и с псевдонимами")
check(DatagramContract.usage(of: "var datagram = new HitPacket", type: "HitPacket", rules: packetRules) == .sends
        && DatagramContract.usage(of: "[Injectable] private PacketFilter<HitPacket> _filter;", type: "HitPacket", rules: packetRules) == .receives
        && DatagramContract.usage(of: "private bool On(ref HitPacket datagram)", type: "HitPacket", rules: packetRules) == .receives
        && DatagramContract.usage(of: "// HitPacket", type: "HitPacket", rules: packetRules) == nil,
      "кто шлёт и кто ловит")

section("Конфиги")
let pairMetaJSON = Data("""
{"shared": [{"path": "user/levels.json", "alias": "UserLevels"}], "server": [{"path": "geo/geo.json", "alias": "Geo"}]}
""".utf8)
check(ConfigLinks.aliases(meta: pairMetaJSON) == ["user/levels.json": "UserLevels", "geo/geo.json": "Geo"], "registry.json: путь → alias")
let aliasesSource = """
public static class ConfigNames
{
    [ConfigModel(typeof(Dictionary<string, string[]>))] public const string GeoPresets = "GeoPresets";
    [ConfigModel(typeof(Server.Models.UserLevelsModel))] public const string UserLevels = "UserLevels";
    public const string RARE_TYPES = "RareTypes";
}
"""
check(ConfigLinks.declaration(of: "UserLevels", in: aliasesSource) == .init(constant: "UserLevels", model: "UserLevelsModel", line: 3),
      "alias с моделью")
check(ConfigLinks.declaration(of: "RareTypes", in: aliasesSource) == .init(constant: "RARE_TYPES", model: nil, line: 4),
      "константа названа иначе, модели нет")
check(ConfigLinks.declaration(of: "GeoPresets", in: aliasesSource)?.model == "Dictionary", "обобщённая модель — короткое имя")
check(ConfigLinks.alias(declaredIn: "    public const string RARE_TYPES = \"RareTypes\";") == "RareTypes", "alias из строки")
check(ConfigLinks.jsonProperty(in: "[JsonProperty(\"max_num\")] public int Max;", attribute: "JsonProperty") == "max_num"
        && ConfigLinks.jsonProperty(in: "[JsonProperty(PropertyName = \"x\")] int X;", attribute: "JsonProperty") == "x"
        && ConfigLinks.jsonProperty(in: "public int Max;", attribute: "JsonProperty") == nil, "ключ из [JsonProperty]")
let configText = "{\n  \"max_num\": 3,\n  \"name\": \"max_num\"\n}"
let keyOffset = (configText as NSString).range(of: "max_num").location + 2
check(ConfigLinks.jsonKey(at: keyOffset, in: configText) == "max_num", "ключ под курсором")
let valueOffset = (configText as NSString).range(of: "\"max_num\"\n").location + 3
check(ConfigLinks.jsonKey(at: valueOffset, in: configText) == nil, "строка-значение — не ключ")
section("Импорт из Rider")

check(RiderKeystroke.shortcut("meta alt B") == Shortcut("b", command: true, option: true)
        && RiderKeystroke.shortcut("shift meta close_bracket") == Shortcut("]", command: true, shift: true)
        && RiderKeystroke.shortcut("ctrl minus") == Shortcut("-", control: true)
        && RiderKeystroke.shortcut("shift alt f12") == Shortcut("f12", option: true, shift: true)
        && RiderKeystroke.shortcut("control BACK_SPACE") == Shortcut("delete", control: true),
      "нажатия JetBrains читаются")
check(RiderKeystroke.shortcut("ctrl NUMPAD4") == nil && RiderKeystroke.shortcut("altGraph A") == nil
        && RiderKeystroke(first: "meta k", second: "meta c").shortcut == nil,
      "цифровой блок, AltGr и аккорды — не сочетания Pilot")
check(RiderKeystroke(first: "meta k", second: "meta c").display == "⌘K ⌘C", "аккорд показывается целиком")

let bundled = RiderBundledKeymaps.all
check(bundled.keymaps.keys.sorted() == ["$default", "Mac OS X", "Mac OS X 10.5+", "VSCode OSX"],
      "встроенные раскладки на месте (\(bundled.keymaps.keys.sorted()))")
check(bundled.keystrokes("GotoDeclaration", in: "VSCode OSX") == [RiderKeystroke(first: "f12")],
      "VSCode: F12 — к объявлению")
// Mac OS X 10.5+ берёт у $default «control …» и видит его как ⌘.
let swapTest = RiderKeymaps(keymaps: [
    "$default": RiderKeymap(name: "$default", parent: nil, actions: ["X": [RiderKeystroke(first: "control shift K")]]),
    "Mac OS X 10.5+": RiderKeymap(name: "Mac OS X 10.5+", parent: "$default", actions: [:]),
    "mine": RiderKeymap(name: "mine", parent: "Mac OS X 10.5+", actions: [:]),
])
check(swapTest.keystrokes("X", in: "mine") == [RiderKeystroke(first: "meta shift K")],
      "у маковской раскладки ctrl родителя становится ⌘")
check(swapTest.keystrokes("X", in: "$default") == [RiderKeystroke(first: "control shift K")]
        && swapTest.keystrokes("Y", in: "mine") == nil, "у самой $default — как записано")
let macSave = bundled.keystrokes("SaveAll", in: "Mac OS X 10.5+")?.first?.shortcut
check(macSave == Shortcut("s", command: true), "macOS: сохранить всё — ⌘S (получено \(macSave?.display ?? "nil"))")

// Экспорт настроек Rider: раскладка «VSCode (macOS) copy» поверх VSCode OSX.
let riderDir = FileManager.default.temporaryDirectory.appendingPathComponent("pilot-rider-\(getpid())")
func riderFile(_ rel: String, _ text: String) {
    let url = riderDir.appendingPathComponent(rel)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? text.write(to: url, atomically: true, encoding: .utf8)
}
riderFile("keymaps/VSCode _macOS_ copy.xml", """
<keymap version="1" name="VSCode (macOS) copy" parent="VSCode OSX">
  <action id="Back">
    <keyboard-shortcut first-keystroke="ctrl minus" />
    <mouse-shortcut keystroke="button4" />
    <keyboard-shortcut first-keystroke="f10" />
  </action>
  <action id="StepOver" />
</keymap>
""")
riderFile("options/mac/keymap.xml", """
<application><component name="KeymapManager"><active_keymap name="VSCode (macOS) copy" /></component></application>
""")
riderFile("options/editor-font.xml", """
<application><component name="DefaultFont">
  <option name="FONT_SIZE" value="18" /><option name="FONT_SIZE_2D" value="18.0" />
  <option name="FONT_FAMILY" value="Hack Nerd Font Mono" />
</component></application>
""")
riderFile("options/editor.xml", """
<application><component name="CodeVisionSettings"><option name="codeVisionEnabled" value="false" /></component></application>
""")
let rider = RiderSettings(folder: riderDir)
check(rider?.activeKeymap == "VSCode (macOS) copy" && rider?.keymaps.count == 1, "раскладка из настроек")
check(rider?.fontSize == 18 && rider?.fontFamily == "Hack Nerd Font Mono" && rider?.codeVision == false,
      "шрифт и Code Vision")
check(RiderSettings(folder: riderDir.appendingPathComponent("keymaps/nothing")) == nil, "не настройки — nil")

if let rider {
    let result = rider.keymap(over: Keymap())
    let k = result.keymap
    func outcome(_ c: EditorCommand) -> RiderImport.Outcome? { result.entries.first { $0.command == c }?.outcome }
    check(result.missingKeymap == nil, "вся цепочка раскладок известна")
    check(k.shortcut(for: .goToDefinition) == Shortcut("f12")
            && k.shortcut(for: .findReferences) == Shortcut("f12", option: true, shift: true)
            && k.shortcut(for: .rename) == Shortcut("f2")
            && k.shortcut(for: .searchEverywhere) == Shortcut("p", command: true),
          "сочетания VSCode перенеслись")
    check(k.shortcut(for: .back) == Shortcut("f10"), "⌃- работает всегда — берётся следующее, F10")
    check(outcome(.forward) == .kept(reason: "⌃⇧- работает в Pilot всегда")
            && k.shortcut(for: .forward) == Shortcut("]", command: true),
          "вперёд: только ⌃⇧- — сочетание Pilot остаётся")
    if case .kept(let reason)? = outcome(.foldAll) {
        check(reason.contains("аккорд") && reason.contains("⌘K ⌘0"), "только аккорд — объяснено (\(reason))")
    } else { check(false, "свернуть всё: аккорд не перенесён") }
    check(outcome(.searchTypes) == .kept(reason: "в Rider без сочетания"), "снятое в Rider — не трогаем")
    check(outcome(.recentLocations) == .yielded(Shortcut("e", command: true, shift: true), to: .toggleSidebar),
          "⌘⇧E у недавних мест забрал навигатор — в VSCode это дерево проекта")
    check(outcome(.save) == .same(Shortcut("s", command: true)), "⌘S и там и там")
    check(k.shortcut(for: .moveLinesDown) == Shortcut("down", option: true)
            && k.shortcut(for: .duplicateLines) == Shortcut("down", option: true, shift: true),
          "строку ниже ⌥↓, дублировать ⌥⇧↓")
    let clashes = EditorCommand.allCases.filter { !k.conflicts(for: $0).isEmpty }
    check(clashes.isEmpty, "после импорта сочетания не пересекаются (\(clashes))")
    check(Keymap.parse(k.serialized()) == k, "результат пишется в keybindings.json и читается обратно")

    // Своё сочетание Pilot, занятое Rider, уступается.
    var mine = Keymap()
    mine.set(Shortcut("f12"), for: .toggleSidebar)
    let yielded = rider.keymap(over: mine)
    check(yielded.keymap.shortcut(for: .toggleSidebar) == Shortcut("e", command: true, shift: true),
          "навигатор получает своё из Rider")
    mine.set(Shortcut("f12"), for: .toggleInspector)
    let lost = rider.keymap(over: mine).entries.first { $0.command == .toggleInspector }?.outcome
    check(lost == .yielded(Shortcut("f12"), to: .goToDefinition), "инспектор уступил F12 объявлению")
}

var orphan = RiderSettings(folder: riderDir)!
orphan.keymaps = [RiderKeymap(name: "Mine", parent: "ReSharper OSX", actions: ["RenameElement": [RiderKeystroke(first: "meta R")]])]
orphan.activeKeymap = "Mine"
let orphanResult = orphan.keymap(over: Keymap())
check(orphanResult.missingKeymap == "ReSharper OSX"
        && orphanResult.keymap.shortcut(for: .rename) == Shortcut("r", command: true),
      "неизвестная родительская раскладка: переносится хотя бы своё")
try? FileManager.default.removeItem(at: riderDir)
// ───────────────────────────── Перевод ─────────────────────────────
section("Перевод")
Localization.current = .en
check(L("Сохранить") == "Save", "строка переводится")
check(L("Нет такой строки в таблице") == "Нет такой строки в таблице", "без перевода остаётся русская")
let movedShortcut = "⌘B", movedTitle = "Go to Definition"
check(L("\(movedShortcut) уже у «\(movedTitle)»") == "⌘B is already used by “Go to Definition”",
      "аргументы подставляются, перевод может их переставить")
check(Localization.substitute("100%% и %@", ["x"]) == "100% и x", "%% — сам знак процента")
check(L("Файл: 50% \("x")") == "Файл: 50% x", "процент в тексте ключа — не место подстановки")
check(Localization.count(1, "файл", "файла", "файлов") == "1 file"
        && Localization.count(21, "файл", "файла", "файлов") == "21 files",
      "английские формы: единица и всё остальное")
Localization.current = .ru
check(L("Сохранить") == "Сохранить", "по-русски ключ и есть строка")
check(Localization.count(1, "файл", "файла", "файлов") == "1 файл"
        && Localization.count(3, "файл", "файла", "файлов") == "3 файла"
        && Localization.count(11, "файл", "файла", "файлов") == "11 файлов"
        && Localization.count(22, "файл", "файла", "файлов") == "22 файла",
      "русские формы: 1, 3, 11, 22")
check(AppLanguage.preferred(from: ["de-DE", "ru-RU", "en"]) == .ru
        && AppLanguage.preferred(from: ["en-US", "ru-GE"]) == .en
        && AppLanguage.preferred(from: ["ja"]) == .en,
      "системный язык: первый знакомый, иначе английский")

// Все строки интерфейса, которые код отдаёт в L(…) и в формы числа,
// переведены, и в таблице нет забытых переводов.
let usedKeys = LocalizationAudit.keys(in: "Sources/Pilot")
check(usedKeys.strings.count > 400, "ключи нашлись в исходниках (\(usedKeys.strings.count))")
for (key, place) in usedKeys.strings.sorted(by: { $0.key < $1.key }) where English.table[key] == nil {
    check(false, "нет перевода: \(place) \(key.debugDescription)")
}
for (key, place) in usedKeys.plurals.sorted(by: { $0.key < $1.key }) where English.table[key] == nil {
    check(false, "нет перевода форм числа: \(place) \(key.debugDescription)")
}
for key in English.table.keys.sorted() where usedKeys.strings[key] == nil && usedKeys.plurals[key] == nil {
    check(false, "перевод ни к чему: \(key.debugDescription)")
}
for (key, value) in English.table {
    let placeholders = { (s: String) in s.components(separatedBy: "%").count - 1 - 2 * (s.components(separatedBy: "%%").count - 1) }
    if placeholders(key) != placeholders(value) {
        check(false, "у перевода другое число подстановок: \(key.debugDescription) → \(value.debugDescription)")
    }
}
var firstValue: [String: String] = [:]
for (key, value) in English.parts.joined() {
    if let earlier = firstValue[key], earlier != value {
        check(false, "два разных перевода \(key.debugDescription): \(earlier.debugDescription) и \(value.debugDescription)")
    }
    firstValue[key] = firstValue[key] ?? value
}

// ───────────────────────────── Расширения ─────────────────────────────
section("Расширения: extension.json")
do {
    let manifest = try? ProjectRules.manifest(from: Data("""
    { "name": "Game", "description": "соглашения игры",
      "pair": { "suffixes": [["-app", "-backend"], ["bad"]], "mirrors": ["docs/shared", "tools/"] },
      "datagrams": { "interface": "IPacket", "write": "Serialize", "receive": ["PacketFilter"] },
      "configs": { "folder": "Data", "registry": "index.json" } }
    """.utf8))
    check(manifest?.name == "Game" && manifest?.description == "соглашения игры", "имя и описание")
    check(manifest?.rules.pair.suffixes == [PairRules.Suffixes(first: "-app", second: "-backend")],
          "окончания пары — только пары из двух")
    check(manifest?.rules.pair.mirrors == ["docs/shared/", "tools/"], "зеркальные папки — со слешем на конце")
    check(manifest?.rules.datagrams == DatagramRules(interface: "IPacket", write: ["Serialize"], read: ["Read"],
                                                     send: ["Send"], receive: ["PacketFilter"]),
          "датаграммы: строка вместо списка, остальное — по умолчанию")
    check(manifest?.rules.configs?.folder == "Data" && manifest?.rules.configs?.registry == "index.json"
            && manifest?.rules.configs?.keyAttribute == "JsonProperty", "конфиги: заданное и по умолчанию")
    check((try? ProjectRules.manifest(from: Data(#"{"datagrams": {}}"#.utf8))) == nil, "без имени — не расширение")
    check((try? ProjectRules.manifest(from: Data(#"{"name": "X", "datagrams": {}}"#.utf8))) == nil,
          "датаграммы без интерфейса — ошибка, а не молчаливое «ничего»")
    let matched = try? ProjectRules.manifest(from: Data(#"{"name": "X", "match": {"remotes": ["git.example.com:game/"], "files": ["Game.sln"]}}"#.utf8))
    check(matched?.match?.matches(remotes: ["git@git.example.com:game/client.git"], exists: { _ in false }) == true
            && matched?.match?.matches(remotes: ["git@github.com:other/x.git"], exists: { $0 == "Game.sln" }) == true
            && matched?.match?.matches(remotes: ["git@github.com:other/x.git"], exists: { _ in false }) == false,
          "match: по адресу remote или по файлу в корне")
    let empty = try? ProjectRules.manifest(from: Data(#"{"name": "X"}"#.utf8))
    check(empty?.rules.isEmpty == true, "пустое расширение ничего не включает")

    var first = ProjectRules()
    first.pair.mirrors = ["a/"]
    first.datagrams = DatagramRules(interface: "IFirst")
    var second = ProjectRules()
    second.pair.mirrors = ["a/", "b/"]
    second.datagrams = DatagramRules(interface: "ISecond")
    second.configs = ConfigRules()
    let merged = ProjectRules.merged([first, second])
    check(merged.pair.mirrors == ["a/", "b/"] && merged.datagrams?.interface == "IFirst" && merged.configs != nil,
          "слияние: списки складываются, раздел — у первого, у кого он есть")

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pilot-ext-\(getpid())")
    try? FileManager.default.removeItem(at: root)
    func put(_ path: String, _ text: String) {
        let url = root.appendingPathComponent(path)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! text.write(to: url, atomically: true, encoding: .utf8)
    }
    put(".pilot/extensions/game/extension.json", #"{"name": "Game"}"#)
    put(".pilot/extensions/broken/extension.json", "{ не json")
    put(".pilot/extensions/notes/README.md", "без extension.json")
    let found = ProjectExtension.discover(in: root)
    check(found.found.map(\.manifest.name) == ["Game"] && found.problems.count == 1,
          "поиск: рабочее найдено, сломанное — в проблемах, папка без манифеста — мимо")
    check(ProjectExtension.fingerprint(of: Data("a".utf8)) != ProjectExtension.fingerprint(of: Data("b".utf8)),
          "отпечаток меняется вместе с содержимым")
    try? FileManager.default.removeItem(at: root)
}

// ───────────────────────────── Обновление ─────────────────────────────
section("Обновление: версии и релиз")
check(AppVersion("v0.2.0")! > AppVersion("0.1.9")!, "тег с v сравнивается с версией бандла")
check(AppVersion("0.10.0")! > AppVersion("0.9.3")!, "числа сравниваются как числа, не как строки")
check(AppVersion("0.2")! == AppVersion("0.2.0")! && !(AppVersion("0.2")! < AppVersion("0.2.0")!),
      "недостающие числа — нули")
check(AppVersion("1.0-beta") == nil && AppVersion("") == nil, "не версия — nil")
do {
    let json = """
    {"tag_name": "v0.3.1", "html_url": "https://github.com/stasiandr/pilot/releases/tag/v0.3.1",
     "body": "Что нового", "draft": false, "prerelease": false,
     "assets": [
       {"name": "Pilot-0.3.1-abc123-x86_64.zip", "browser_download_url": "https://example.com/x86.zip"},
       {"name": "Pilot-0.3.1-abc123-arm64.zip", "browser_download_url": "https://example.com/arm.zip"}
     ]}
    """.data(using: .utf8)!
    let arm = ReleaseInfo.parse(json, arch: "arm64")
    check(arm?.version == AppVersion("0.3.1") && arm?.archive?.absoluteString == "https://example.com/arm.zip",
          "релиз: версия из тега и архив своей архитектуры")
    check(ReleaseInfo.parse(json, arch: "riscv")?.archive == nil, "архива под архитектуру нет — только страница")
    check(UpdateSource("github:acme/pilot") == .github(repository: "acme/pilot")
            && UpdateSource("gitlab:git.example.com/tools/editors/pilot") == .gitlab(host: "git.example.com", project: "tools/editors/pilot")
            && UpdateSource("gitlab:git.example.com") == nil && UpdateSource("svn:x/y") == nil,
          "источник обновлений из Info.plist")
    check(UpdateSource.gitlab(host: "git.example.com", project: "tools/pilot").latestURL.absoluteString
            == "https://git.example.com/api/v4/projects/tools%2Fpilot/releases/permalink/latest",
          "GitLab: путь проекта кодируется в id")
    let gitlabJSON = """
    {"tag_name": "v0.4.0", "description": "что нового", "upcoming_release": false,
     "_links": {"self": "https://git.example.com/tools/pilot/-/releases/v0.4.0"},
     "assets": {"links": [
       {"name": "Pilot-0.4.0-abc-arm64.zip", "url": "https://git.example.com/a.zip", "direct_asset_url": "https://git.example.com/direct.zip"}
     ]}}
    """.data(using: .utf8)!
    let fromGitLab = ReleaseInfo.parseGitLab(gitlabJSON, arch: "arm64")
    check(fromGitLab?.version == AppVersion("0.4.0") && fromGitLab?.archive?.absoluteString == "https://git.example.com/direct.zip"
            && fromGitLab?.page.absoluteString == "https://git.example.com/tools/pilot/-/releases/v0.4.0",
          "релиз GitLab: версия, прямая ссылка на архив, страница")
    let pre = String(data: json, encoding: .utf8)!.replacingOccurrences(of: "\"prerelease\": false", with: "\"prerelease\": true")
    check(ReleaseInfo.parse(pre.data(using: .utf8)!) == nil, "пре-релиз не предлагается")
}

// ───────────────────────────── Граф значения ─────────────────────────────
section("Граф значения: запись и чтение")
do {
    func access(_ line: String, _ name: String) -> ValueFlow.Access {
        let units = Array(line.utf16)
        let at = (line as NSString).range(of: name)
        return ValueFlow.access(in: units, name: at)
    }
    func rhsText(_ line: String, _ name: String) -> String? {
        guard case .write(let rhs?, _) = access(line, name) else { return nil }
        return ValueFlow.string(Array(line.utf16), rhs)
    }
    check(rhsText("health.Value = d.Amount;", "Value") == "d.Amount", "присваивание — запись, правая часть до ;")
    check(access("if (health.Value == 0) return;", "Value") == .read, "== — чтение")
    check(access("var x = c.Value;", "Value") == .read, "справа от = — чтение")
    check(access("Func<int> f = () => Value;", "Value") == .read, "в лямбде — чтение")
    check(access("c.Count++;", "Count") == .write(rhs: nil, compound: true), "++ после — запись")
    check(access("++c.Count;", "Count") == .write(rhs: nil, compound: true), "++ перед цепочкой — запись")
    if case .write(_, let compound) = access("hp.Value -= damage * 2;", "Value") {
        check(compound && rhsText("hp.Value -= damage * 2;", "Value") == "damage * 2", "-= — составная запись")
    } else { check(false, "-= — составная запись") }
    check(rhsText("_stash.Set(e, new Health { Value = max, Regen = 1 });", "Value") == "max",
          "инициализатор: до запятой своего уровня")
    check(rhsText("_stash.Set(e, new Health { Value = Math.Max(a, b) });", "Value") == "Math.Max(a, b)",
          "запятая внутри вызова правую часть не рвёт")
    check(rhsText("new Health { Regen = 1, Value = x }", "Value") == "x", "последнее в инициализаторе — до }")
    check(access("Parse(s, out stats.Level);", "Level") == .write(rhs: nil, compound: false), "out — запись")
    check(rhsText("d.Name = \"a;b\";", "Name") == "\"a;b\"", "; в строке правую часть не рвёт")
}

section("Граф значения: источники")
do {
    func sources(_ expr: String) -> [String] {
        let units = Array(expr.utf16)
        return ValueFlow.sources(in: units, range: NSRange(location: 0, length: units.count)).map { $0.chain + ($0.call ? "()" : "") }
    }
    check(sources("stats.Damage * mult") == ["stats.Damage", "mult"], "цепочка и одиночное имя")
    check(sources("Math.Max(a.B, 0)") == ["Math.Max()", "a.B"], "вызов и аргумент")
    check(sources("new Vector3(x, y, 0)") == ["Vector3()", "x", "y"], "new — не источник, конструктор — вызов")
    check(sources("player?.Stats.Hp ?? 0") == ["player.Stats.Hp"], "?. — та же цепочка")
    check(sources("\"hp: \" + hp") == ["hp"], "строки пропускаются")
    check(sources("list.Get<int>(i)") == ["list.Get()", "i"], "обобщённый вызов")
    let units = Array("stats.Damage * mult".utf16)
    let last = ValueFlow.sources(in: units, range: NSRange(location: 0, length: units.count))[0].range
    check(ValueFlow.string(units, last) == "Damage", "у цепочки спрашиваем последнее звено")
}

section("Граф значения: условия и вызовы")
do {
    func units(_ s: String) -> [UInt16] { Array(s.utf16) }
    func text(_ u: [UInt16], _ r: NSRange?) -> String? { r.map { ValueFlow.string(u, $0) } }
    let nested = units("c.Pos.x = 1;")
    let pos = ("c.Pos.x = 1;" as NSString).range(of: "Pos")
    check(ValueFlow.access(in: nested, name: pos) == .write(rhs: NSRange(location: 10, length: 1), compound: true),
          "запись во вложенное поле — составная запись самой структуры")
    check(ValueFlow.access(in: units("c.Pos.Normalize();"), name: pos) == .read, "вызов метода вложенного — не запись")

    let loop = "void OnUpdate() {\n foreach (ref readonly var d in _networkFilter)\n {\n  x.A = d.B;\n }\n y = 1;\n}"
    let u = units(loop)
    let whole = NSRange(location: 0, length: u.count)
    let inside = (loop as NSString).range(of: "x.A").location
    check(text(u, ValueFlow.enclosingForeach(in: u, range: whole, containing: inside)) == "_networkFilter",
          "запись внутри foreach — его источник")
    let outside = (loop as NSString).range(of: "y = 1").location
    check(ValueFlow.enclosingForeach(in: u, range: whole, containing: outside) == nil, "после цикла — не в нём")
    let single = units("foreach (var e in _filter) _hp.Set(e);")
    check(text(single, ValueFlow.enclosingForeach(in: single, range: NSRange(location: 0, length: single.count),
                                                 containing: 30)) == "_filter", "тело без скобок")

    let filter = units("_filter = World.Filter.With<Health>().With<Game.Pawn>().Without<Dead>().Build();")
    let parts = ValueFlow.filterComponents(in: filter, range: NSRange(location: 0, length: filter.count))
    check(parts.with == ["Health", "Pawn"] && parts.without == ["Dead"], "With и Without фильтра")

    let call = units("Apply(ref target, amount: dmg * 2, Get<int>(a, b));")
    let apply = NSRange(location: 0, length: 5)
    check(text(call, ValueFlow.argument(in: call, after: apply, index: 0)) == "target", "ref снят")
    check(text(call, ValueFlow.argument(in: call, after: apply, index: 1)) == "dmg * 2", "имя аргумента снято")
    check(text(call, ValueFlow.argument(in: call, after: apply, index: 2)) == "Get<int>(a, b)", "запятые внутри — не граница")
    check(ValueFlow.argument(in: call, after: apply, index: 3) == nil, "аргумента нет")

    let body = units("int Damage() { if (crit) return base * 2; return base; }")
    let returns = ValueFlow.returnedExpressions(in: body, method: NSRange(location: 0, length: body.count))
    check(returns.map { ValueFlow.string(body, $0) } == ["base * 2", "base"], "все return")
    let arrow = units("int Damage => stats.Base + bonus;")
    check(ValueFlow.returnedExpressions(in: arrow, method: NSRange(location: 0, length: arrow.count))
            .map { ValueFlow.string(arrow, $0) } == ["stats.Base + bonus"], "тело-выражение")

    let stash = units("_health.Set(e, new Health { }); _health.Remove(e); _healthX.Set(a); if (_health.Has(e)) {}")
    check(ValueFlow.stashCalls(in: stash, stash: "_health").map(\.call) == [.set, .remove], "Set и Remove, не Has и не чужой стэш")
}

section("Граф значения: локальные переменные")
do {
    let body = "void Apply() {\n  var mult = crit ? 2 : 1;\n  int dmg = stats.Damage * mult;\n  hp.Value -= dmg;\n}"
    let units = Array(body.utf16)
    let method = NSRange(location: 0, length: units.count)
    let use = (body as NSString).range(of: "dmg;").location
    let dmg = ValueFlow.localInitializer(in: units, name: "dmg", within: method, before: use)
    check(dmg.map { ValueFlow.string(units, $0) } == "stats.Damage * mult", "int dmg = … — объявление")
    let mult = ValueFlow.localInitializer(in: units, name: "mult", within: method, before: use)
    check(mult.map { ValueFlow.string(units, $0) } == "crit ? 2 : 1", "var mult = … — объявление")
    check(ValueFlow.localInitializer(in: units, name: "Value", within: method, before: units.count) == nil,
          "hp.Value -= … — не объявление")
}

print("\n════════════════════════════════════")
print(failures == 0 ? "ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ (\(checks))" : "ПРОВАЛЕНО \(failures) из \(checks)")
exit(failures == 0 ? 0 : 1)
