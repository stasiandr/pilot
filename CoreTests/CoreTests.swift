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
check(PaletteMode.allCases.count == 9, "режимов палитры девять")
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

let assetIndex = UnityAssetIndex.build(root: unityRoot)
check(assetIndex.count == 4, "в индексе ассеты, папка и скрипт пакета (получено \(assetIndex.count))")
check(assetIndex.path(for: UnityGUID(playerGUID)!) == "Assets/Scripts/Player.cs", "GUID -> путь скрипта")
check(assetIndex.displayName(for: UnityGUID(playerGUID)!) == "Player", "имя скрипта = имя класса")
check(assetIndex.path(for: UnityGUID(packageScriptGUID)!) == "Library/PackageCache/com.acme.tools@abc123/Runtime/Tool.cs",
      "скрипты пакетов резолвятся из PackageCache")
check(assetIndex.guid(forAsset: "Assets/UI/Button.prefab")?.description == buttonPrefabGUID, "путь -> GUID")
check(assetIndex.path(for: UnityGUID("44444444444444444444444444444444")!) == "Assets/Scripts", "у папок тоже есть GUID")

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

print("\n════════════════════════════════════")
print(failures == 0 ? "ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ (\(checks))" : "ПРОВАЛЕНО \(failures) из \(checks)")
exit(failures == 0 ? 0 : 1)
