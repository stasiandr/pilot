import Foundation

/// Unity-семантика поверх лексической структуры C#-файла.
///
/// Языковой сервер знает C#, но не знает Unity: для него `Update()` —
/// обычный приватный метод без единого вызова. На деле его вызывает движок,
/// и при чтении кода это первое, что хочется видеть. Узнаём такие методы
/// по имени — так же, как их находит сам Unity.
enum UnityCSharp {

    /// Сообщения, которые движок вызывает сам: MonoBehaviour, ScriptableObject,
    /// редакторские классы и системы ECS.
    static let eventFunctions: Set<String> = [
        // Жизненный цикл
        "Awake", "Start", "Update", "FixedUpdate", "LateUpdate", "OnEnable", "OnDisable",
        "OnDestroy", "OnValidate", "Reset", "OnApplicationFocus", "OnApplicationPause",
        "OnApplicationQuit", "OnGUI",
        // Физика
        "OnCollisionEnter", "OnCollisionStay", "OnCollisionExit",
        "OnCollisionEnter2D", "OnCollisionStay2D", "OnCollisionExit2D",
        "OnTriggerEnter", "OnTriggerStay", "OnTriggerExit",
        "OnTriggerEnter2D", "OnTriggerStay2D", "OnTriggerExit2D",
        "OnControllerColliderHit", "OnJointBreak", "OnJointBreak2D",
        "OnParticleCollision", "OnParticleTrigger", "OnParticleSystemStopped",
        // Ввод мышью
        "OnMouseDown", "OnMouseDrag", "OnMouseEnter", "OnMouseExit", "OnMouseOver",
        "OnMouseUp", "OnMouseUpAsButton",
        // Рендеринг
        "OnBecameVisible", "OnBecameInvisible", "OnWillRenderObject", "OnRenderObject",
        "OnPreCull", "OnPreRender", "OnPostRender", "OnRenderImage",
        "OnDrawGizmos", "OnDrawGizmosSelected",
        // Анимация и звук
        "OnAnimatorIK", "OnAnimatorMove", "OnAudioFilterRead", "OnDidApplyAnimationProperties",
        // Иерархия и UI
        "OnTransformParentChanged", "OnTransformChildrenChanged", "OnBeforeTransformParentChanged",
        "OnRectTransformDimensionsChange", "OnCanvasGroupChanged",
        // Редактор
        "OnInspectorGUI", "OnSceneGUI", "OnPreviewGUI", "HasPreviewGUI", "OnHeaderGUI",
        "CreateInspectorGUI", "CreateGUI", "OnFocus", "OnLostFocus", "OnHierarchyChange",
        "OnProjectChange", "OnSelectionChange", "OnInspectorUpdate",
        "OnWizardCreate", "OnWizardUpdate", "OnWizardOtherButton",
        "OnPreprocessTexture", "OnPostprocessTexture", "OnPreprocessModel", "OnPostprocessModel",
        "OnPreprocessAudio", "OnPostprocessAudio", "OnPostprocessAllAssets",
        // ECS
        "OnCreate", "OnUpdate", "OnStartRunning", "OnStopRunning",
    ]

    /// Атрибуты, с которыми поле попадает в сериализацию, а значит — в инспектор.
    static let serializationAttributes = ["SerializeField", "SerializeReference"]

    /// Уточняет виды элементов структуры: методы-сообщения движка
    /// и сериализуемые поля.
    static func annotate(_ outline: [OutlineItem], units: [UInt16]) -> [OutlineItem] {
        outline.map { item in
            var item = item
            switch item.kind {
            case .method where eventFunctions.contains(item.name):
                item.kind = .unityMessage
            case .field, .property:
                if hasSerializationAttribute(before: item.range.location, in: units) {
                    item.kind = .serializedField
                }
            default:
                break
            }
            return item
        }
    }

    /// Есть ли `[SerializeField]` между предыдущим объявлением и именем.
    /// Идём назад до `;`, `{` или `}` вне квадратных скобок — это граница
    /// предыдущей конструкции. Атрибуты вида `[field: SerializeField]`
    /// у автосвойств тоже сюда попадают.
    static func hasSerializationAttribute(before offset: Int, in units: [UInt16]) -> Bool {
        var i = min(offset, units.count) - 1
        var bracketDepth = 0
        var sawBracket = false
        let lowerBound = max(0, offset - 600)   // объявление не бывает длиннее
        while i >= lowerBound {
            let c = units[i]
            if c == 0x5D { bracketDepth += 1; sawBracket = true }        // ]
            else if c == 0x5B { bracketDepth -= 1 }                     // [
            else if bracketDepth == 0 && (c == 0x3B || c == 0x7B || c == 0x7D) { break }
            i -= 1
        }
        guard sawBracket else { return false }
        let text = String(decoding: units[max(0, i + 1)..<min(offset, units.count)], as: UTF16.self)
        return serializationAttributes.contains { text.contains($0) }
    }

    /// Где объявлен `class Имя` — туда ведёт переход со ссылки на скрипт.
    /// Строка и колонка имени (UTF-16), в координатах LSP.
    static func classDeclaration(named name: String, in text: String) -> (line: Int, column: Int)? {
        var line = 0
        for row in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if let range = row.range(of: "class " + name) {
                let after = range.upperBound
                let boundary = after == row.endIndex
                    || !(row[after].isLetter || row[after].isNumber || row[after] == "_")
                let before = range.lowerBound == row.startIndex
                    || !(row[row.index(before: range.lowerBound)].isLetter)
                let trimmed = row.drop(while: { $0 == " " || $0 == "\t" })
                if boundary && before && !trimmed.hasPrefix("//") && !trimmed.hasPrefix("*") {
                    let column = row[..<range.lowerBound].utf16.count + 6
                    return (line, column)
                }
            }
            line += 1
        }
        return nil
    }

    // MARK: - Типы полей для инспектора

    /// Что инспектору нужно знать о скрипте: тип каждого поля и enum'ы,
    /// объявленные в файле. В YAML bool — это `0`/`1`, а enum — число;
    /// только по скрипту видно, что показать переключатель или список.
    struct ScriptInfo: Sendable {
        var fieldTypes: [String: String] = [:]
        var enums: [String: [EnumMember]] = [:]

        /// Тип поля по ключу из YAML: `<Health>k__BackingField` → поле `Health`.
        func type(ofKey key: String) -> String? {
            if key.hasPrefix("<"), let close = key.firstIndex(of: ">") {
                return fieldTypes[String(key[key.index(after: key.startIndex)..<close])]
            }
            return fieldTypes[key]
        }
    }

    struct EnumMember: Sendable, Equatable {
        var name: String
        var value: Int
    }

    static func scriptInfo(from text: String) -> ScriptInfo {
        let clean = stripComments(text)
        return ScriptInfo(fieldTypes: fieldTypes(in: clean), enums: enums(in: clean))
    }

    private static let fieldPattern = try! NSRegularExpression(pattern:
        #"(?:\[[^\]\n]*\]\s*)*(?:\b(?:public|private|protected|internal|static|readonly|new|volatile)\s+)*"#
        + #"\b([A-Za-z_][\w.]*(?:<[^;=(){}]*?>)?(?:\[\])?\??)\s+([A-Za-z_]\w*)\s*(?:=[^;{}]*)?;"#)
    private static let propertyPattern = try! NSRegularExpression(pattern:
        #"\b([A-Za-z_][\w.]*(?:<[^;=(){}]*?>)?(?:\[\])?\??)\s+([A-Za-z_]\w*)\s*\{\s*(?:get|set|private|protected|internal|init)"#)
    private static let notTypes: Set<String> = ["return", "throw", "yield", "goto", "break", "continue",
                                                "else", "case", "using", "namespace", "await", "new"]

    static func fieldTypes(in text: String) -> [String: String] {
        var result: [String: String] = [:]
        let ns = text as NSString
        for pattern in [fieldPattern, propertyPattern] {
            for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let type = ns.substring(with: match.range(at: 1))
                let name = ns.substring(with: match.range(at: 2))
                guard !notTypes.contains(type), result[name] == nil else { continue }
                result[name] = type
            }
        }
        return result
    }

    private static let enumPattern = try! NSRegularExpression(pattern:
        #"(\[\s*(?:System\.)?Flags(?:Attribute)?\s*\][\s\S]{0,80}?)?\benum\s+([A-Za-z_]\w*)\s*(?::\s*\w+)?\s*\{([^}]*)\}"#)

    /// Enum'ы файла с числовыми значениями. `[Flags]` пропускаем: там
    /// значение — сумма флагов, и список его не покажет.
    static func enums(in text: String) -> [String: [EnumMember]] {
        var result: [String: [EnumMember]] = [:]
        let ns = text as NSString
        for match in enumPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard match.range(at: 1).location == NSNotFound else { continue }
            let name = ns.substring(with: match.range(at: 2))
            let body = ns.substring(with: match.range(at: 3))
            var members: [EnumMember] = []
            var next = 0
            var understood = true
            for part in body.split(separator: ",") {
                var item = part.trimmingCharacters(in: .whitespacesAndNewlines)
                while item.hasPrefix("["), let close = item.firstIndex(of: "]") {   // [InspectorName("…")]
                    item = item[item.index(after: close)...].trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard !item.isEmpty else { continue }
                let pieces = item.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                var value = next
                if pieces.count == 2 {
                    guard let explicit = integer(pieces[1]) else { understood = false; break }   // выражение — не берёмся
                    value = explicit
                }
                members.append(EnumMember(name: pieces[0], value: value))
                next = value + 1
            }
            if understood, !members.isEmpty { result[name] = members }
        }
        return result
    }

    private static func integer(_ text: String) -> Int? {
        if let v = Int(text) { return v }
        if text.hasPrefix("0x") || text.hasPrefix("0X") { return Int(text.dropFirst(2), radix: 16) }
        let shift = text.components(separatedBy: "<<").map { $0.trimmingCharacters(in: .whitespaces) }
        if shift.count == 2, let a = Int(shift[0]), let b = Int(shift[1]) { return a << b }
        return nil
    }

    /// Комментарии мешают регуляркам: закомментированное поле — не поле.
    private static func stripComments(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        var it = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = nil
        var inLine = false, inBlock = false, inString = false
        var previous: Unicode.Scalar = " "
        while let c = pending ?? it.next() {
            pending = nil
            if inLine { if c == "\n" { inLine = false; out.unicodeScalars.append(c) }; previous = c; continue }
            if inBlock {
                if previous == "*" && c == "/" { inBlock = false; previous = " "; continue }
                if c == "\n" { out.unicodeScalars.append(c) }
                previous = c
                continue
            }
            if inString {
                out.unicodeScalars.append(c)
                if c == "\"" && previous != "\\" { inString = false }
                previous = c
                continue
            }
            if c == "/" {
                let n = it.next()
                if n == "/" { inLine = true; previous = " "; continue }
                if n == "*" { inBlock = true; previous = " "; continue }
                out.unicodeScalars.append(c)
                pending = n
                previous = c
                continue
            }
            if c == "\"" { inString = true }
            out.unicodeScalars.append(c)
            previous = c
        }
        return out
    }
}
