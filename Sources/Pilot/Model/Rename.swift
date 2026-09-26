import Foundation

/// Правила переименования, не зависящие от того, где стоит имя: какое имя
/// годится и то ли имя стоит там, где его собираются заменить. Что и где
/// менять, решает Rustlyn.
enum Rename {

    /// Ключевые слова C#: такое имя пишется только с `@`.
    static let keywords: Set<String> = [
        "abstract", "as", "base", "bool", "break", "byte", "case", "catch", "char", "checked", "class",
        "const", "continue", "decimal", "default", "delegate", "do", "double", "else", "enum", "event",
        "explicit", "extern", "false", "finally", "fixed", "float", "for", "foreach", "goto", "if",
        "implicit", "in", "int", "interface", "internal", "is", "lock", "long", "namespace", "new", "null",
        "object", "operator", "out", "override", "params", "private", "protected", "public", "readonly",
        "ref", "return", "sbyte", "sealed", "short", "sizeof", "stackalloc", "static", "string", "struct",
        "switch", "this", "throw", "true", "try", "typeof", "uint", "ulong", "unchecked", "unsafe", "ushort",
        "using", "virtual", "void", "volatile", "while",
    ]

    /// Что не так с новым именем, или `nil`, если годится.
    static func problem(with name: String) -> String? {
        let bare = name.hasPrefix("@") ? String(name.dropFirst()) : name
        guard let first = bare.unicodeScalars.first else { return L("Имя пустое") }
        let letter = CharacterSet.letters.union(CharacterSet(charactersIn: "_"))
        let part = letter.union(.decimalDigits)
        guard letter.contains(first) else { return L("Имя начинается с буквы или _") }
        guard bare.unicodeScalars.allSatisfy(part.contains) else {
            return L("В имени только буквы, цифры и _")
        }
        if keywords.contains(bare) && !name.hasPrefix("@") {
            return L("«\(bare)» — ключевое слово; как имя — только @\(bare)")
        }
        return nil
    }

    /// Стоит ли на этом месте то имя, что переименовывают. Правки для
    /// других файлов Rustlyn считает в тексте последней компиляции, а
    /// открытая вкладка могла с тех пор уйти вперёд: правка не на своём
    /// месте испортила бы код, поэтому такой файл пропускается целиком.
    /// Атрибут в скобках пишется без `Attribute`: `[Mark]` у `MarkAttribute`.
    static func isOccurrence(_ written: String, of old: String) -> Bool {
        let bare = { (name: String) in name.hasPrefix("@") ? String(name.dropFirst()) : name }
        let written = bare(written), old = bare(old)
        return !written.isEmpty && (written == old || old == written + "Attribute")
    }

    /// Метка UTF-8 в начале файла: её нет в тексте, но она была в байтах,
    /// и после записи должна остаться — иначе дифф на весь файл.
    static let utf8BOM = Data([0xEF, 0xBB, 0xBF])

    /// Правки одного текста, применённые с конца: ранние диапазоны не
    /// сдвигаются от поздних.
    static func apply(_ edits: [(range: NSRange, text: String)], to text: String) -> String? {
        let ns = NSMutableString(string: text)
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            guard NSMaxRange(edit.range) <= ns.length else { return nil }
            ns.replaceCharacters(in: edit.range, with: edit.text)
        }
        return ns as String
    }
}
