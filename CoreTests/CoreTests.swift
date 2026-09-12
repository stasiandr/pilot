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
for expected in ["Acme", "IInvoiceStore", "InvoiceService", "FindAsync",
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
check(named(cs, "Acme")?.kind == .namespace, "C#: namespace распознан")
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


// ─────────────────────────── Git: диф строк ───────────────────────────
section("Git: диф строк")

func diff(_ old: String, _ new: String, maxEdits: Int = LineDiff.maxEdits) -> [LineDiff.Change] {
    LineDiff.changes(old: old, new: new, maxEdits: maxEdits)
}
func ch(_ kind: LineDiff.Kind, _ lines: Range<Int>) -> LineDiff.Change {
    LineDiff.Change(kind: kind, lines: lines)
}

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
    check(tracked?.changes == [ch(.modified, 1..<2), ch(.added, 3..<4)],
          "полоски против HEAD (получено \(String(describing: tracked?.changes)))")

    let fresh = Git.lineChanges(text: "fresh\n", path: "src/new.txt", repository: repo)
    check(fresh?.tracked == false && fresh?.changes == [ch(.added, 0..<1)], "новый файл — весь добавлен")
    let ignoredFile = Git.lineChanges(text: "noise\n", path: "debug.log", repository: repo)
    check(ignoredFile?.tracked == false && ignoredFile?.changes.isEmpty == true, "игнорируемый файл — без полосок")

    let liveBlame = Git.blame(text: edited, path: "src/app.txt", repository: repo, lineCount: 5)
    check(liveBlame?.commit(atLine: 0)?.author == "Pilot Test", "blame: автор неизменённой строки")
    check(liveBlame?.commit(atLine: 0)?.summary == "Initial", "blame: сообщение коммита")
    check(liveBlame?.commit(atLine: 1)?.isUncommitted == true, "blame: изменённая строка не закоммичена")
    check(liveBlame?.commit(atLine: 3)?.isUncommitted == true, "blame: дописанная строка не закоммичена")
}


// ────────────────────────── Режимы палитры ──────────────────────────
section("Режимы палитры")

// CaseIterable + исчерпывающие switch: если в enum добавится режим,
// а ветку забудут — это упадёт здесь, а не при сборке приложения.
check(PaletteMode.allCases.count == 5, "режимов палитры пять")
for mode in PaletteMode.allCases {
    check(!mode.placeholder.isEmpty, "у режима \(mode) есть подпись поля")
    check(!mode.icon.isEmpty, "у режима \(mode) есть иконка")
}
check(!PaletteMode.files.requiresLanguageServer, "поиск файлов не требует LSP")
check(!PaletteMode.outline.requiresLanguageServer, "структура файла не требует LSP")
check(PaletteMode.symbols.requiresLanguageServer, "символы проекта требуют LSP")
check(PaletteMode.references.requiresLanguageServer, "использования требуют LSP")
check(!PaletteMode.changes.requiresLanguageServer, "изменённые файлы не требуют LSP")

print("\n════════════════════════════════════")
print(failures == 0 ? "ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ (\(checks))" : "ПРОВАЛЕНО \(failures) из \(checks)")
exit(failures == 0 ? 0 : 1)
