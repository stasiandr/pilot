import Foundation

/// Что мерить: проект и места в нём. Файл сценариев — JSON (для OneState —
/// `Extensions/onestate/perf.json`); `bin/pilot-perf` отдаёт его путь в
/// `PILOT_PERF_CONFIG`.
struct PerfConfig: Decodable {
    /// Корень проекта, абсолютный путь.
    var project: String

    struct Palette: Decodable {
        var text: String
        var rounds: Int?
        var intervalMs: Double?
    }

    /// Файл, строка и столбец с единицы — как в `pilot File.cs:12:5`.
    struct Place: Decodable {
        var file: String
        var line: Int
        var column: Int
    }

    struct Editor: Decodable {
        var file: String
        var line: Int
        var column: Int
        var text: String
        var rounds: Int?
        var intervalMs: Double?
    }

    var palette: Palette?
    var editor: Editor?
    /// Файлы для переходов, пути от корня.
    var files: [String]?
    /// Сколько секунд смотреть на простаивающее окно.
    var idleSeconds: Double?
    /// Запросы к индексам ⌘P без окна.
    var queries: [String]?
    /// Строка для поиска по тексту без окна.
    var textQuery: String?
    /// Вопросы к компилятору без окна: подсветка и диагностика — файл,
    /// остальное — место в файле.
    var completion: Place?
    var references: Place?
    var definition: Place?
    /// Правка без записи на диск и компиляция после неё: `editText`
    /// вставляется в место `edit`.
    var edit: Place?
    var editText: String?
    /// Графы значения: `Файл.cs:строка:столбец`.
    var graphs: [String]?

    static let environment = ProcessInfo.processInfo.environment

    /// `PILOT_PERF=ui` — сценарии в окне, `engine:<группа>` — без окна.
    static var mode: String? { environment["PILOT_PERF"] }

    static func load() -> PerfConfig? {
        guard let path = environment["PILOT_PERF_CONFIG"] else {
            PerfReport.log("нет PILOT_PERF_CONFIG — файла сценариев")
            return nil
        }
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(PerfConfig.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            PerfReport.log("не прочитать \(path): \(error)")
            return nil
        }
    }

    /// Сценарии из `PILOT_PERF_ONLY` (через запятую); нет его — все.
    static func wants(_ scenario: String) -> Bool {
        guard let only = environment["PILOT_PERF_ONLY"], !only.isEmpty else { return true }
        return only.split(separator: ",").contains { scenario.hasPrefix($0) || $0 == scenario }
    }

    var root: URL { URL(fileURLWithPath: project, isDirectory: true) }

    func url(_ relative: String) -> URL { root.appendingPathComponent(relative) }
}

/// Результаты: строка JSON на сценарий — в `PILOT_PERF_OUT` (или stdout).
/// Имя метрики кончается единицей, по ней `bin/pilot-perf` выбирает, с
/// каким допуском сравнивать: `minstr` — миллионы инструкций (главное),
/// `ms`, `mb`, `n` — штуки.
enum PerfReport {
    private static let lock = NSLock()

    static func emit(_ scenario: String, _ metrics: [String: Double], info: [String: String] = [:]) {
        let record: [String: Any] = ["scenario": scenario, "metrics": metrics, "info": info]
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        lock.lock()
        defer { lock.unlock() }
        if let path = PerfConfig.environment["PILOT_PERF_OUT"] {
            // Дописать: сценарий, упавший на середине, не стирает прошлые.
            if let handle = FileHandle(forWritingAtPath: path) ?? {
                FileManager.default.createFile(atPath: path, contents: nil)
                return FileHandle(forWritingAtPath: path)
            }() {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            }
        } else {
            print(line, terminator: "")
            fflush(stdout)
        }
    }

    /// Ход замера — в stderr: в выводе результатов его быть не должно.
    static func log(_ message: String) {
        FileHandle.standardError.write(Data("perf: \(message)\n".utf8))
    }

    static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// Метрики отрезка под общим префиксом.
    static func metrics(_ prefix: String, _ result: PerfSpan.Result) -> [String: Double] {
        [
            "\(prefix).ms": result.wallMs,
            "\(prefix).minstr": result.instructions,
            "\(prefix).cpu.ms": result.cpuMs,
        ]
    }
}

extension Double {
    /// Байты — в мегабайты.
    static func mb(_ bytes: UInt64) -> Double { Double(bytes) / 1_048_576 }
}
