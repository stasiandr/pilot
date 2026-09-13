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
@main struct App {
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

// ────────────────────────── LSP: демон ──────────────────────────
section("LSP / демон")

/// Ждёт условия, не дольше `timeout` секунд.
func eventually(_ timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return condition()
}

final class ResultBox<T>: @unchecked Sendable { var value: Result<T, Error>? }

/// Асинхронный вызов из синхронного кода тестов. nil — не дождались.
func blocking<T>(_ body: @escaping @Sendable () async throws -> T) -> Result<T, Error>? {
    let done = DispatchSemaphore(value: 0)
    let box = ResultBox<T>()
    Task.detached {
        do { box.value = .success(try await body()) } catch { box.value = .failure(error) }
        done.signal()
    }
    return done.wait(timeout: .now() + 5) == .success ? box.value : nil
}

/// Уведомления, которые клиент получил через демона.
final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var methods: [String] = []
    func add(_ method: String) { lock.lock(); methods.append(method); lock.unlock() }
    func count(_ method: String) -> Int { lock.lock(); defer { lock.unlock() }; return methods.filter { $0 == method }.count }
}

do {
    signal(SIGPIPE, SIG_IGN)
    let tmp = NSTemporaryDirectory()
    // `cat` вместо Roslyn: он возвращает всё, что ему пишут, поэтому через
    // эхо видно, что именно демон переслал серверу и сколько раз.
    let catConfig = ServerConfig(id: "cat", languageId: "plaintext", fileExtensions: ["txt"],
                                 command: ["/bin/cat"], displayName: "cat")
    let rootA = URL(fileURLWithPath: tmp + "pilot-daemon-a")
    let rootB = URL(fileURLWithPath: tmp + "pilot-daemon-b")
    for root in [rootA, rootB] {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    final class Exited: @unchecked Sendable { var value = false }
    var sockets: [String] = []

    func makeDaemon(_ policy: LSPDaemon.Policy, build: String = "b1",
                    executable: String? = nil) -> (LSPDaemon, String, Exited) {
        let socket = tmp + "pilot-test-\(UUID().uuidString.prefix(8)).sock"
        sockets.append(socket)
        let daemon = LSPDaemon(socketPath: socket, build: build, executablePath: executable, policy: policy)
        let exited = Exited()
        daemon.onExit = { exited.value = true }
        try? daemon.start()
        return (daemon, socket, exited)
    }

    func client(_ socket: String, root: URL, heard: Heard? = nil) -> LSPClient? {
        guard let fd = UnixSocket.connectTo(socket) else { return nil }
        let c = LSPClient(config: catConfig, root: root)
        if let heard { c.onNotification = { method, _ in heard.add(method) } }
        c.connect(daemonSocket: fd)
        return c
    }

    var quiet = LSPDaemon.Policy()
    quiet.sweepInterval = 3600
    quiet.exitWhenEmptyAfter = 3600

    // Два клиента, один сервер.
    var keepAll = quiet
    keepAll.keepIfLoadTookAtLeast = 0
    let (daemon, socket, _) = makeDaemon(keepAll)
    let heardA = Heard(), heardB = Heard()
    let a = client(socket, root: rootA, heard: heardA)!
    let attachA = blocking { try await a.attach(build: "b1") }
    check((try? attachA?.get()) == false, "первый клиент запускает сервер")
    check((try? blocking { try await a.initialize() }?.get()) != nil, "initialize через демона")
    let b = client(socket, root: rootA, heard: heardB)!
    check((try? blocking { try await b.attach(build: "b1") }?.get()) == true,
          "второй клиент того же проекта получает работающий сервер")
    check((try? blocking { try await b.initialize() }?.get()) != nil, "второй initialize — из сохранённого")
    check(daemon.snapshot().servers == 1, "сервер один на двоих")

    let ping = blocking { try await b.request("pilot/ping", [:], timeout: 2) }
    check((try? ping?.get()) is NSNull, "запрос проходит через демона к серверу и обратно")

    // Общий документ открывается на сервере один раз и закрывается последним.
    let doc = rootA.appendingPathComponent("a.txt")
    a.didOpen(url: doc, languageId: "plaintext", text: "x")
    b.didOpen(url: doc, languageId: "plaintext", text: "x")
    check(eventually { heardA.count("textDocument/didOpen") == 1 }, "didOpen дошёл до сервера")
    Thread.sleep(forTimeInterval: 0.2)
    check(heardB.count("textDocument/didOpen") == 1, "второй didOpen того же файла сервер не получил")
    a.stop()
    check(eventually { daemon.snapshot().connections == 1 }, "отключение клиента демон заметил")
    Thread.sleep(forTimeInterval: 0.2)
    check(heardB.count("textDocument/didClose") == 0, "файл ещё открыт у второго — didClose нет")
    b.didClose(url: doc)
    check(eventually { heardB.count("textDocument/didClose") == 1 }, "последний закрывший — didClose дошёл")

    // Клиентов нет, а дорогой (по политике) сервер остаётся.
    b.stop()
    check(eventually { daemon.snapshot().connections == 0 }, "все клиенты отключились")
    check(daemon.snapshot().servers == 1, "дорогой сервер пережил уход клиентов")
    let c = client(socket, root: rootA)!
    check((try? blocking { try await c.attach(build: "b1") }?.get()) == true, "новый клиент застаёт его живым")
    c.stop()

    // Лимит серверов без клиентов: лишний — самый давний — уходит.
    let d = client(socket, root: rootB)!
    _ = blocking { try await d.attach(build: "b1") }
    _ = blocking { try await d.initialize() }
    check(daemon.snapshot().servers == 2, "второй проект — второй сервер")
    d.stop()
    check(eventually { daemon.snapshot().connections == 0 }, "и этот клиент ушёл")
    // Лимит проверяем на копии политики: подменить её у живого демона нельзя.
    var one = keepAll
    one.maxIdleServers = 1
    let (limited, limitedSocket, _) = makeDaemon(one)
    for root in [rootA, rootB] {
        let e = client(limitedSocket, root: root)!
        _ = blocking { try await e.attach(build: "b1") }
        _ = blocking { try await e.initialize() }
        e.stop()
    }
    check(eventually { limited.snapshot().servers == 1 }, "без клиентов держим не больше одного — по политике")

    // Дешёвый сервер (cat поднимается мгновенно) после ухода клиента не держим.
    let (cheap, cheapSocket, _) = makeDaemon(quiet)
    let f = client(cheapSocket, root: rootA)!
    _ = blocking { try await f.attach(build: "b1") }
    _ = blocking { try await f.initialize() }
    f.stop()
    check(eventually { cheap.snapshot().servers == 0 }, "быстро поднимающийся сервер останавливается сразу")

    // Сборки не совпали. Исполняемый файл демона не менялся — устарел клиент.
    let exe = tmp + "pilot-fake-exe-\(UUID().uuidString.prefix(8))"
    FileManager.default.createFile(atPath: exe, contents: Data())
    let (fresh, freshSocket, freshExited) = makeDaemon(quiet, build: LSPDaemon.buildID(executable: exe), executable: exe)
    let old = client(freshSocket, root: rootA)!
    if case .failure(RPCError.serverError(let code, _))? = blocking({ try await old.attach(build: "old") }) {
        check(code == LSPDaemon.staleClientCode, "старый клиент получает отказ, демон остаётся")
    } else {
        check(false, "старый клиент получает отказ, демон остаётся")
    }
    check(!freshExited.value && fresh.snapshot().connections >= 0, "свежий демон не уходит из-за старого клиента")
    old.stop()
    // Файл демона пересобрали — устарел сам демон: отказывает и уходит.
    Thread.sleep(forTimeInterval: 0.01)
    try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: exe)
    let fresher = client(freshSocket, root: rootA)!
    let staleExit = Heard()
    fresher.onExit = { _ in staleExit.add("exit") }
    if case .failure(RPCError.serverError(let code, _))? = blocking({ try await fresher.attach(build: "new") }) {
        check(code == LSPDaemon.staleDaemonCode, "пересобранный Pilot: демон сообщает, что устарел")
    } else {
        check(false, "пересобранный Pilot: демон сообщает, что устарел")
    }
    check(eventually { freshExited.value }, "устаревший демон уходит сам")
    check(eventually { staleExit.count("exit") == 1 }, "клиент видит, что демон закрыл соединение")
    check(UnixSocket.connectTo(freshSocket) == nil, "сокет устаревшего демона убран")
    try? FileManager.default.removeItem(atPath: exe)

    // Демона выключили в настройках: Pilot просит его уйти.
    let (quitting, quitSocket, quitExited) = makeDaemon(quiet)
    LSPDaemon.requestQuit(socketPath: quitSocket)
    check(eventually { quitExited.value }, "по pilot/quit демон уходит")
    LSPDaemon.requestQuit(socketPath: quitSocket)   // демона уже нет — просто ничего
    _ = daemon; _ = limited; _ = cheap; _ = quitting
    for socket in sockets { unlink(socket) }
    for root in [rootA, rootB] { try? FileManager.default.removeItem(at: root) }
}

do {
    var config = ServerConfig(id: "x", languageId: "csharp", fileExtensions: ["cs", "csx"],
                              command: ["/bin/x", "--stdio"], displayName: "X")
    config.settings = ["a.b": false]
    config.opensSolution = true
    config.projectsLoadedNotification = "done"
    let back = ServerConfig(json: config.json)
    check(back?.command == config.command && back?.fileExtensions == config.fileExtensions
          && back?.settings["a.b"] as? Bool == false && back?.opensSolution == true
          && back?.projectsLoadedNotification == "done",
          "конфигурация сервера переживает JSON — так она уходит демону")
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
    var config = ServerConfig(id: "t", languageId: "csharp", fileExtensions: [], command: ["x"],
                              displayName: "t")
    config.settings = ServerRegistry.roslynSettings
    let request = json("{\"items\":[{\"section\":\"csharp|inlay_hints.csharp_enable_inlay_hints_for_types\"},{\"section\":\"projects.dotnet_enable_automatic_restore\"},{\"scopeUri\":\"file:///a\"}]}")
    let answer = config.configurationResponse(request)
    check(answer.count == 3, "configuration: по ответу на каждый запрошенный элемент")
    check(answer[0] is NSNull, "configuration: неизвестная секция -> null")
    check(answer[1] as? Bool == false, "configuration: автоматический restore выключен")
    check(answer[2] is NSNull, "configuration: элемент без секции -> null")
    check(config.configurationResponse(nil).isEmpty, "configuration: без параметров -> пустой массив")
}

do {
    // Папка с исполняемым `mono` выпадает из PATH, остальные — в том же порядке.
    let fm = FileManager.default
    let monoDir = NSTemporaryDirectory() + "pilot-mono-\(UUID().uuidString)"
    try? fm.createDirectory(atPath: monoDir, withIntermediateDirectories: true)
    fm.createFile(atPath: monoDir + "/mono", contents: Data("#!/bin/sh\n".utf8),
                  attributes: [.posixPermissions: 0o755])
    let stripped = DotnetRuntime.pathWithoutMono("/usr/bin:\(monoDir):/bin")
    check(stripped == "/usr/bin:/bin", "PATH без Mono (получено \(stripped))")
    check(DotnetRuntime.pathWithoutMono("/usr/bin:/bin") == "/usr/bin:/bin", "PATH без Mono не меняется")
    try? fm.removeItem(atPath: monoDir)
}

let slnText = """
Microsoft Visual Studio Solution File, Format Version 11.00
Project("{FAE04EC0-301F-11D3-BF4B-00C04F79EFBC}") = "Assembly-CSharp", "Assembly-CSharp.csproj", "{4DF3AB5E}"
EndProject
Project("{2150E333-8FDC-42A3-9474-1A3956D46DE8}") = "Folder", "Folder", "{0000}"
EndProject
Project("{FAE04EC0-301F-11D3-BF4B-00C04F79EFBC}") = "UI", "Sub\\UI.csproj", "{1111}"
EndProject
"""
check(ServerRegistry.projectCount(solutionText: slnText, isXML: false) == 2,
      "sln: считаются проекты, но не папки решения")
let slnxText = """
<Solution>
  <Folder Name="/src/">
    <Project Path="src/App/App.csproj" />
    <Project Path="src/Lib/Lib.csproj" />
  </Folder>
</Solution>
"""
check(ServerRegistry.projectCount(solutionText: slnxText, isXML: true) == 2, "slnx: два проекта")

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
}


// ─────────────────────────── GitLab: remote ───────────────────────────
section("GitLab: remote")

let scpRemote = GitLabRemote.parse("git@gitlab.com:stasiandr/dacha-simulator.git")
check(scpRemote == GitLabRemote(host: "gitlab.com", projectPath: "stasiandr/dacha-simulator"), "scp-форма")
check(GitLabRemote.parse("ssh://git@gitlab.example.com:2222/group/sub/app.git")
        == GitLabRemote(host: "gitlab.example.com", projectPath: "group/sub/app"), "ssh:// с портом и подгруппой")
check(GitLabRemote.parse("https://oauth2:secret@GitLab.com/group/app/")
        == GitLabRemote(host: "gitlab.com", projectPath: "group/app"), "https с логином, регистр хоста, хвостовой слеш")
check(GitLabRemote.parse("/Users/me/repos/app.git") == nil, "локальный путь — не GitLab")
check(GitLabRemote.parse("git@gitlab.com:app.git") == nil, "без владельца — не проект")
check(scpRemote?.encodedProject == "stasiandr%2Fdacha-simulator", "слеш в пути проекта кодируется для API")


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

let comment = mrDiff.commentLines(forNewLine: 6)
check(comment.old == 6 && comment.new == 7, "комментарий к неизменённой строке — обе стороны, с единицы")
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


// ────────────────────────── Режимы палитры ──────────────────────────
section("Режимы палитры")

// CaseIterable + исчерпывающие switch: если в enum добавится режим,
// а ветку забудут — это упадёт здесь, а не при сборке приложения.
check(PaletteMode.allCases.count == 7, "режимов палитры семь")
for mode in PaletteMode.allCases {
    check(!mode.placeholder.isEmpty, "у режима \(mode) есть подпись поля")
    check(!mode.icon.isEmpty, "у режима \(mode) есть иконка")
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
]
for (path, text) in navFiles {
    let url = navRoot.appendingPathComponent(path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? text.write(to: url, atomically: true, encoding: .utf8)
}
let symbols = SymbolIndex.build(root: navRoot, files: Array(navFiles.keys), shouldStop: { false })
check(symbols != nil, "индекс символов построен")
let symbolIndex = symbols ?? SymbolIndex(root: navRoot)
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
                      "Player", "Player", "PlayerSystem", "Stash", "World"],
      "типы для ⇧⇧ из индекса символов (получено \(derivedNames))")

// кэш
let symbolRoundTrip = SymbolIndex.deserialize(symbolIndex.serialized(), root: navRoot)
check(symbolRoundTrip?.symbols == symbolIndex.symbols && symbolRoundTrip?.files == symbolIndex.files,
      "кэш символов: туда и обратно без потерь")
check(symbolRoundTrip?.typesByName["Player"]?.count == 2, "после загрузки из кэша таблицы построены")
check(SymbolIndex.deserialize("pilot-types 1\nF\tx", root: navRoot) == nil, "чужой формат кэша отвергается")
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

print("\n════════════════════════════════════")
print(failures == 0 ? "ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ (\(checks))" : "ПРОВАЛЕНО \(failures) из \(checks)")
exit(failures == 0 ? 0 : 1)
