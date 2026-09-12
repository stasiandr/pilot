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
}
