import Foundation

enum TokenKind: UInt8 {
    case plain, keyword, type, string, escape, number, comment, docComment
    case function, punctuation, preprocessor, attribute, constant, operatorTok
}

struct StringSpec {
    let open: [UInt8]
    let close: [UInt8]
    let escapes: Bool
    let multiline: Bool
}

struct LanguageSpec {
    var name: String
    var lineComments: [[UInt8]] = []
    var docLineComments: [[UInt8]] = []
    var blockComment: (open: [UInt8], close: [UInt8])?
    var nestedBlockComments: Bool = false
    var strings: [StringSpec] = []
    var keywords: Set<String> = []
    var constants: Set<String> = []
    var typeKeywords: Set<String> = []
    /// '#' в C#/C/Swift — директивы препроцессора или атрибуты
    var preprocessorPrefix: UInt8? = nil
    /// '@' в Swift/Java/Kotlin/C# — атрибуты/аннотации
    var attributePrefix: UInt8? = nil
    /// Считать ли Идентификаторы-С-Большой-Буквы типами (работает для C#, Swift, Java)
    var capitalizedIsType: Bool = true

    // --- структурный разбор для навигации по файлу ---
    /// Как в этом языке опознаётся объявление.
    var outline: OutlineStyle = .none
    /// Ключевое слово -> что оно объявляет. Следующий идентификатор и есть имя.
    var declarationKeywords: [String: OutlineKind] = [:]
    /// Модификаторы: встретив их слева от имени, считаем, что это объявление.
    var modifierKeywords: Set<String> = []
    /// Контекстные ключевые слова: подсвечиваются как ключевые, но могут быть
    /// и обычным именем — `public Color value;`, `var get = …`.
    var contextualKeywords: Set<String> = []
    /// Блоки задаются отступом, а не скобками (Python).
    var indentBased = false
    /// `ключ:` красится как имя (YAML).
    var keysBeforeColon = false

    static func s(_ str: String) -> [UInt8] { Array(str.utf8) }
}

enum Languages {

    static func detect(filename: String) -> LanguageSpec? {
        let lower = filename.lowercased()
        let ext = (lower as NSString).pathExtension
        if ext.isEmpty {
            switch lower {
            case "makefile": return make
            case "dockerfile": return shell
            default: return nil
            }
        }
        return byExtension[ext]
    }

    static let byExtension: [String: LanguageSpec] = {
        var m: [String: LanguageSpec] = [:]
        for e in ["cs", "csx"] { m[e] = csharp }
        for e in ["swift"] { m[e] = swift }
        for e in ["c", "h", "cpp", "cc", "cxx", "hpp", "hh", "m", "mm"] { m[e] = cfamily }
        for e in ["js", "jsx", "mjs", "cjs", "ts", "tsx"] { m[e] = javascript }
        for e in ["py", "pyi"] { m[e] = python }
        for e in ["rs"] { m[e] = rust }
        for e in ["go"] { m[e] = golang }
        for e in ["java"] { m[e] = java }
        for e in ["kt", "kts"] { m[e] = kotlin }
        for e in ["rb"] { m[e] = ruby }
        for e in ["php"] { m[e] = php }
        for e in ["sh", "bash", "zsh", "fish"] { m[e] = shell }
        for e in ["json", "jsonc"] { m[e] = json }
        for e in ["yaml", "yml"] { m[e] = yaml }
        for e in ["toml"] { m[e] = toml }
        for e in ["xml", "html", "htm", "xaml", "csproj", "props", "targets", "plist", "svg", "axaml"] { m[e] = xml }
        for e in ["css", "scss", "less"] { m[e] = css }
        for e in ["sql"] { m[e] = sql }
        for e in ["md", "markdown"] { m[e] = markdown }
        // Unity. Сериализованные ассеты — YAML со своими тегами; .meta — тоже.
        for e in ["unity", "prefab", "asset", "mat", "anim", "controller", "overridecontroller",
                  "playable", "mask", "physicmaterial", "physicsmaterial2d", "mixer", "rendertexture",
                  "lighting", "spriteatlas", "spriteatlasv2", "terrainlayer", "signal", "preset",
                  "guiskin", "fontsettings", "flare", "brush", "cubemap", "giparams", "scenetemplate",
                  "vfxoperator", "vfxblock", "meta"] { m[e] = unityYAML }
        for e in ["shader"] { m[e] = shaderLab }
        for e in ["hlsl", "hlslinc", "cginc", "compute", "glsl", "glslinc", "raytrace", "fx"] { m[e] = hlsl }
        for e in ["asmdef", "asmref", "inputactions", "shadergraph", "shadersubgraph", "index",
                  "buildreport", "vfx"] where m[e] == nil { m[e] = json }
        for e in ["uxml"] { m[e] = xml }
        for e in ["uss", "tss"] { m[e] = css }
        return m
    }()

    // MARK: - Определения языков

    static let csharp: LanguageSpec = {
        var l = LanguageSpec(name: "C#")
        l.lineComments = [LanguageSpec.s("//")]
        l.docLineComments = [LanguageSpec.s("///")]
        l.blockComment = (LanguageSpec.s("/*"), LanguageSpec.s("*/"))
        l.strings = [
            StringSpec(open: LanguageSpec.s("\"\"\""), close: LanguageSpec.s("\"\"\""), escapes: false, multiline: true),
            StringSpec(open: LanguageSpec.s("@\""), close: LanguageSpec.s("\""), escapes: false, multiline: true),
            StringSpec(open: LanguageSpec.s("$\""), close: LanguageSpec.s("\""), escapes: true, multiline: false),
            StringSpec(open: LanguageSpec.s("\""), close: LanguageSpec.s("\""), escapes: true, multiline: false),
            StringSpec(open: LanguageSpec.s("'"), close: LanguageSpec.s("'"), escapes: true, multiline: false),
        ]
        l.preprocessorPrefix = 0x23   // '#'
        l.attributePrefix = nil
        l.keywords = ["abstract","as","async","await","base","break","case","catch","checked","class","const",
            "continue","default","delegate","do","else","enum","event","explicit","extern","finally","fixed",
            "for","foreach","get","goto","if","implicit","in","init","interface","internal","is","lock",
            "namespace","new","operator","out","override","params","private","protected","public","readonly",
            "record","ref","return","sealed","set","sizeof","stackalloc","static","struct","switch","this",
            "throw","try","typeof","unchecked","unsafe","using","value","var","virtual","volatile","when",
            "where","while","yield","nameof","partial","global","required","scoped","with","and","or","not"]
        l.constants = ["true","false","null","default"]
        l.typeKeywords = ["bool","byte","char","decimal","double","dynamic","float","int","long","nint","nuint",
            "object","sbyte","short","string","uint","ulong","ushort","void","Task","List","Dictionary"]
        l.outline = .cFamily
        l.declarationKeywords = [
            "class": .type, "struct": .type, "interface": .type, "record": .type,
            "enum": .type, "namespace": .namespace, "delegate": .method, "event": .field,
        ]
        l.modifierKeywords = ["public","private","protected","internal","static","abstract",
            "virtual","override","sealed","async","extern","unsafe","partial","readonly",
            "const","new","required","file"]
        l.contextualKeywords = ["value","get","set","init","var","partial","record","required","scoped",
            "with","and","or","not","when","where","yield","async","await","global","nameof","file"]
        return l
    }()

    static let swift: LanguageSpec = {
        var l = LanguageSpec(name: "Swift")
        l.lineComments = [LanguageSpec.s("//")]
        l.docLineComments = [LanguageSpec.s("///")]
        l.blockComment = (LanguageSpec.s("/*"), LanguageSpec.s("*/"))
        l.nestedBlockComments = true
        l.strings = [
            StringSpec(open: LanguageSpec.s("\"\"\""), close: LanguageSpec.s("\"\"\""), escapes: true, multiline: true),
            StringSpec(open: LanguageSpec.s("#\""), close: LanguageSpec.s("\"#"), escapes: false, multiline: false),
            StringSpec(open: LanguageSpec.s("\""), close: LanguageSpec.s("\""), escapes: true, multiline: false),
        ]
        l.attributePrefix = 0x40   // '@'
        l.preprocessorPrefix = 0x23
        l.keywords = ["actor","any","as","associatedtype","async","await","borrowing","break","case","catch",
            "class","consuming","continue","convenience","default","defer","deinit","didSet","do","dynamic",
            "each","else","enum","extension","fallthrough","fileprivate","final","for","func","get","guard",
            "if","import","in","indirect","infix","init","inout","internal","is","lazy","let","macro","mutating",
            "nonisolated","nonmutating","open","operator","optional","override","package","postfix","precedencegroup",
            "prefix","private","protocol","public","repeat","required","rethrows","return","sending","set","some",
            "static","struct","subscript","super","switch","throw","throws","try","typealias","unowned","var",
            "weak","where","while","willSet","yield"]
        l.constants = ["true","false","nil","self","Self"]
        l.typeKeywords = ["Int","Int8","Int16","Int32","Int64","UInt","UInt8","UInt16","UInt32","UInt64",
            "Double","Float","Bool","String","Character","Array","Dictionary","Set","Optional","Result","Void"]
        l.outline = .keyword
        l.declarationKeywords = [
            "func": .method, "class": .type, "struct": .type, "enum": .type,
            "protocol": .type, "extension": .type, "actor": .type, "typealias": .type,
            "init": .initializer, "var": .property, "let": .property, "case": .enumCase,
            "subscript": .method, "macro": .method,
        ]
        l.modifierKeywords = ["public","private","fileprivate","internal","open","static",
            "final","override","mutating","nonmutating","lazy","weak","unowned","package"]
        return l
    }()

    static let cfamily: LanguageSpec = {
        var l = LanguageSpec(name: "C/C++")
        l.lineComments = [LanguageSpec.s("//")]
        l.blockComment = (LanguageSpec.s("/*"), LanguageSpec.s("*/"))
        l.strings = [
            StringSpec(open: LanguageSpec.s("\""), close: LanguageSpec.s("\""), escapes: true, multiline: false),
            StringSpec(open: LanguageSpec.s("'"), close: LanguageSpec.s("'"), escapes: true, multiline: false),
        ]
        l.preprocessorPrefix = 0x23
        l.attributePrefix = 0x40
        l.keywords = ["alignas","alignof","and","asm","auto","break","case","catch","class","co_await","co_return",
            "co_yield","concept","const","consteval","constexpr","constinit","const_cast","continue","decltype",
            "default","delete","do","dynamic_cast","else","enum","explicit","export","extern","for","friend","goto",
            "if","inline","mutable","namespace","new","noexcept","not","operator","or","private","protected","public",
            "register","reinterpret_cast","requires","return","sizeof","static","static_assert","static_cast","struct",
            "switch","template","this","thread_local","throw","try","typedef","typeid","typename","union","using",
            "virtual","volatile","while","@interface","@implementation","@end","@property","@synthesize"]
        l.constants = ["true","false","nullptr","NULL","nil","YES","NO"]
        l.typeKeywords = ["bool","char","char8_t","char16_t","char32_t","double","float","int","long","short",
            "signed","unsigned","void","wchar_t","size_t","uint8_t","uint16_t","uint32_t","uint64_t",
            "int8_t","int16_t","int32_t","int64_t","id","instancetype","BOOL","NSInteger","NSUInteger"]
        l.outline = .cFamily
        l.declarationKeywords = [
            "class": .type, "struct": .type, "union": .type, "enum": .type,
            "namespace": .namespace, "typedef": .type, "concept": .type,
        ]
        l.modifierKeywords = ["public","private","protected","static","virtual","inline",
            "explicit","constexpr","consteval","extern","friend","mutable","template"]
        return l
    }()

    static let javascript: LanguageSpec = {
        var l = LanguageSpec(name: "JavaScript/TypeScript")
        l.lineComments = [LanguageSpec.s("//")]
        l.blockComment = (LanguageSpec.s("/*"), LanguageSpec.s("*/"))
        l.strings = [
            StringSpec(open: LanguageSpec.s("`"), close: LanguageSpec.s("`"), escapes: true, multiline: true),
            StringSpec(open: LanguageSpec.s("\""), close: LanguageSpec.s("\""), escapes: true, multiline: false),
            StringSpec(open: LanguageSpec.s("'"), close: LanguageSpec.s("'"), escapes: true, multiline: false),
        ]
        l.attributePrefix = 0x40
        l.keywords = ["abstract","as","async","await","break","case","catch","class","const","constructor","continue",
            "debugger","declare","default","delete","do","else","enum","export","extends","finally","for","from",
            "function","get","if","implements","import","in","infer","instanceof","interface","is","keyof","let",
            "namespace","new","of","override","package","private","protected","public","readonly","return","satisfies",
            "set","static","super","switch","this","throw","try","type","typeof","var","void","while","with","yield"]
        l.constants = ["true","false","null","undefined","NaN","Infinity"]
        l.typeKeywords = ["any","bigint","boolean","never","number","object","string","symbol","unknown",
            "Array","Promise","Record","Partial","Map","Set"]
        l.outline = .keyword
        l.declarationKeywords = [
            "function": .function, "class": .type, "interface": .type, "enum": .type,
            "type": .type, "namespace": .namespace, "const": .variable, "let": .variable,
            "var": .variable,
        ]
        l.modifierKeywords = ["export","default","async","static","public","private",
            "protected","readonly","abstract","declare"]
        return l
    }()

    static let python: LanguageSpec = {
        var l = LanguageSpec(name: "Python")
        l.lineComments = [LanguageSpec.s("#")]
        l.strings = [
            StringSpec(open: LanguageSpec.s("\"\"\""), close: LanguageSpec.s("\"\"\""), escapes: true, multiline: true),
            StringSpec(open: LanguageSpec.s("'''"), close: LanguageSpec.s("'''"), escapes: true, multiline: true),
            StringSpec(open: LanguageSpec.s("\""), close: LanguageSpec.s("\""), escapes: true, multiline: false),
            StringSpec(open: LanguageSpec.s("'"), close: LanguageSpec.s("'"), escapes: true, multiline: false),
        ]
        l.attributePrefix = 0x40
        l.keywords = ["and","as","assert","async","await","break","class","continue","def","del","elif","else",
            "except","finally","for","from","global","if","import","in","is","lambda","match","nonlocal","not",
            "or","pass","raise","return","try","while","with","yield","case"]
        l.constants = ["True","False","None","self","cls"]
        l.typeKeywords = ["int","float","str","bool","bytes","list","dict","tuple","set","frozenset","object",
            "Any","Optional","List","Dict","Tuple","Union","Callable"]
        l.outline = .keyword
        l.indentBased = true
        l.declarationKeywords = ["def": .method, "class": .type, "async": .method]
        return l
    }()

    static let rust: LanguageSpec = {
        var l = LanguageSpec(name: "Rust")
        l.lineComments = [LanguageSpec.s("//")]
        l.docLineComments = [LanguageSpec.s("///"), LanguageSpec.s("//!")]
        l.blockComment = (LanguageSpec.s("/*"), LanguageSpec.s("*/"))
        l.nestedBlockComments = true
        l.strings = [
            StringSpec(open: LanguageSpec.s("r#\""), close: LanguageSpec.s("\"#"), escapes: false, multiline: true),
            StringSpec(open: LanguageSpec.s("\""), close: LanguageSpec.s("\""), escapes: true, multiline: true),
        ]
        l.preprocessorPrefix = 0x23
        l.keywords = ["as","async","await","break","const","continue","crate","dyn","else","enum","extern","fn",
            "for","if","impl","in","let","loop","match","mod","move","mut","pub","ref","return","self","Self",
            "static","struct","super","trait","type","unsafe","use","where","while","union"]
        l.constants = ["true","false","None","Some","Ok","Err"]
        l.typeKeywords = ["bool","char","f32","f64","i8","i16","i32","i64","i128","isize","str","u8","u16",
            "u32","u64","u128","usize","String","Vec","Option","Result","Box","Rc","Arc"]
        l.outline = .keyword
        l.declarationKeywords = [
            "fn": .method, "struct": .type, "enum": .type, "trait": .type,
            "impl": .type, "mod": .namespace, "type": .type, "const": .variable,
            "static": .variable, "union": .type, "macro_rules": .method,
        ]
        l.modifierKeywords = ["pub","async","unsafe","extern","const"]
        return l
    }()

    static let golang: LanguageSpec = {
        var l = LanguageSpec(name: "Go")
        l.lineComments = [LanguageSpec.s("//")]
        l.blockComment = (LanguageSpec.s("/*"), LanguageSpec.s("*/"))
        l.strings = [
            StringSpec(open: LanguageSpec.s("`"), close: LanguageSpec.s("`"), escapes: false, multiline: true),
            StringSpec(open: LanguageSpec.s("\""), close: LanguageSpec.s("\""), escapes: true, multiline: false),
            StringSpec(open: LanguageSpec.s("'"), close: LanguageSpec.s("'"), escapes: true, multiline: false),
        ]
        l.keywords = ["break","case","chan","const","continue","default","defer","else","fallthrough","for","func",
            "go","goto","if","import","interface","map","package","range","return","select","struct","switch","type","var"]
        l.constants = ["true","false","nil","iota"]
        l.typeKeywords = ["bool","byte","complex64","complex128","error","float32","float64","int","int8","int16",
            "int32","int64","rune","string","uint","uint8","uint16","uint32","uint64","uintptr","any"]
        l.outline = .keyword
        l.declarationKeywords = [
            "func": .method, "type": .type, "package": .namespace,
            "const": .variable, "var": .variable,
        ]
        return l
    }()

    static let java: LanguageSpec = {
        var l = LanguageSpec(name: "Java")
        l.lineComments = [LanguageSpec.s("//")]
        l.blockComment = (LanguageSpec.s("/*"), LanguageSpec.s("*/"))
        l.strings = [
            StringSpec(open: LanguageSpec.s("\"\"\""), close: LanguageSpec.s("\"\"\""), escapes: true, multiline: true),
            StringSpec(open: LanguageSpec.s("\""), close: LanguageSpec.s("\""), escapes: true, multiline: false),
            StringSpec(open: LanguageSpec.s("'"), close: LanguageSpec.s("'"), escapes: true, multiline: false),
        ]
        l.attributePrefix = 0x40
        l.keywords = ["abstract","assert","break","case","catch","class","const","continue","default","do","else",
            "enum","extends","final","finally","for","goto","if","implements","import","instanceof","interface",
            "native","new","package","private","protected","public","record","return","sealed","static","strictfp",
            "super","switch","synchronized","this","throw","throws","transient","try","var","volatile","while","yield"]
        l.constants = ["true","false","null"]
        l.typeKeywords = ["boolean","byte","char","double","float","int","long","short","void","String",
            "Integer","Long","Double","Boolean","List","Map","Set","Optional"]
        l.outline = .cFamily
        l.declarationKeywords = [
            "class": .type, "interface": .type, "enum": .type, "record": .type,
            "package": .namespace,
        ]
        l.modifierKeywords = ["public","private","protected","static","final","abstract",
            "synchronized","native","strictfp","default","transient","volatile","sealed"]
        return l
    }()

    static let kotlin: LanguageSpec = {
        var l = LanguageSpec(name: "Kotlin")
        l.lineComments = [LanguageSpec.s("//")]
        l.blockComment = (LanguageSpec.s("/*"), LanguageSpec.s("*/"))
        l.nestedBlockComments = true
        l.strings = [
            StringSpec(open: LanguageSpec.s("\"\"\""), close: LanguageSpec.s("\"\"\""), escapes: false, multiline: true),
            StringSpec(open: LanguageSpec.s("\""), close: LanguageSpec.s("\""), escapes: true, multiline: false),
            StringSpec(open: LanguageSpec.s("'"), close: LanguageSpec.s("'"), escapes: true, multiline: false),
        ]
        l.attributePrefix = 0x40
        l.keywords = ["abstract","actual","annotation","as","break","by","catch","class","companion","const",
            "constructor","continue","crossinline","data","delegate","do","dynamic","else","enum","expect",
            "external","field","final","finally","for","fun","get","if","import","in","infix","init","inline",
            "inner","interface","internal","is","lateinit","noinline","object","open","operator","out","override",
            "package","private","protected","public","reified","return","sealed","set","super","suspend","tailrec",
            "this","throw","try","typealias","val","var","vararg","when","where","while"]
        l.constants = ["true","false","null","it"]
        l.typeKeywords = ["Any","Boolean","Byte","Char","Double","Float","Int","Long","Nothing","Short","String",
            "Unit","List","Map","Set","Array","MutableList"]
        l.outline = .keyword
        l.declarationKeywords = [
            "fun": .method, "class": .type, "interface": .type, "object": .type,
            "enum": .type, "val": .property, "var": .property, "typealias": .type,
        ]
        l.modifierKeywords = ["public","private","protected","internal","open","override",
            "abstract","final","suspend","inline","data","sealed","companion"]
        return l
    }()

    static let ruby: LanguageSpec = {
        var l = LanguageSpec(name: "Ruby")
        l.lineComments = [LanguageSpec.s("#")]
        l.strings = [
            StringSpec(open: LanguageSpec.s("\""), close: LanguageSpec.s("\""), escapes: true, multiline: false),
            StringSpec(open: LanguageSpec.s("'"), close: LanguageSpec.s("'"), escapes: true, multiline: false),
        ]
        l.keywords = ["alias","and","begin","break","case","class","def","defined?","do","else","elsif","end",
            "ensure","for","if","in","module","next","not","or","redo","rescue","retry","return","self","super",
            "then","undef","unless","until","when","while","yield","require","attr_accessor","attr_reader"]
        l.constants = ["true","false","nil","__FILE__","__LINE__"]
        l.capitalizedIsType = true
        l.outline = .keyword
        l.declarationKeywords = ["def": .method, "class": .type, "module": .namespace]
        return l
    }()

    static let php: LanguageSpec = {
        var l = LanguageSpec(name: "PHP")
        l.lineComments = [LanguageSpec.s("//"), LanguageSpec.s("#")]
        l.blockComment = (LanguageSpec.s("/*"), LanguageSpec.s("*/"))
        l.strings = [
            StringSpec(open: LanguageSpec.s("\""), close: LanguageSpec.s("\""), escapes: true, multiline: false),
            StringSpec(open: LanguageSpec.s("'"), close: LanguageSpec.s("'"), escapes: true, multiline: false),
        ]
        l.keywords = ["abstract","and","array","as","break","callable","case","catch","class","clone","const",
            "continue","declare","default","do","echo","else","elseif","empty","enddeclare","endfor","endforeach",
            "endif","endswitch","endwhile","enum","extends","final","finally","fn","for","foreach","function",
            "global","goto","if","implements","include","include_once","instanceof","insteadof","interface","isset",
            "list","match","namespace","new","or","print","private","protected","public","readonly","require",
            "require_once","return","static","switch","throw","trait","try","unset","use","var","while","xor","yield"]
        l.constants = ["true","false","null","TRUE","FALSE","NULL","$this"]
        l.outline = .keyword
        l.declarationKeywords = [
            "function": .method, "class": .type, "interface": .type,
            "trait": .type, "enum": .type, "namespace": .namespace,
        ]
        l.modifierKeywords = ["public","private","protected","static","abstract","final","readonly"]
        return l
    }()

    static let shell: LanguageSpec = {
        var l = LanguageSpec(name: "Shell")
        l.lineComments = [LanguageSpec.s("#")]
        l.strings = [
            StringSpec(open: LanguageSpec.s("\""), close: LanguageSpec.s("\""), escapes: true, multiline: false),
            StringSpec(open: LanguageSpec.s("'"), close: LanguageSpec.s("'"), escapes: false, multiline: false),
        ]
        l.keywords = ["if","then","else","elif","fi","case","esac","for","select","while","until","do","done",
            "in","function","time","coproc","local","export","readonly","declare","typeset","return","source",
            "alias","unalias","set","unset","shift","trap","echo","cd","exit"]
        l.constants = ["true","false"]
        l.capitalizedIsType = false
        l.outline = .keyword
        l.declarationKeywords = ["function": .function]
        return l
    }()

    static let make: LanguageSpec = {
        var l = LanguageSpec(name: "Makefile")
        l.lineComments = [LanguageSpec.s("#")]
        l.keywords = ["ifeq","ifneq","ifdef","ifndef","else","endif","include","define","endef","export",".PHONY"]
        l.capitalizedIsType = false
        return l
    }()

    static let json: LanguageSpec = {
        var l = LanguageSpec(name: "JSON")
        l.lineComments = [LanguageSpec.s("//")]
        l.blockComment = (LanguageSpec.s("/*"), LanguageSpec.s("*/"))
        l.strings = [StringSpec(open: LanguageSpec.s("\""), close: LanguageSpec.s("\""), escapes: true, multiline: false)]
        l.constants = ["true","false","null"]
        l.capitalizedIsType = false
        return l
    }()

    static let yaml: LanguageSpec = {
        var l = LanguageSpec(name: "YAML")
        l.lineComments = [LanguageSpec.s("#")]
        l.strings = [
            StringSpec(open: LanguageSpec.s("\""), close: LanguageSpec.s("\""), escapes: true, multiline: false),
            StringSpec(open: LanguageSpec.s("'"), close: LanguageSpec.s("'"), escapes: false, multiline: false),
        ]
        l.constants = ["true","false","null","yes","no","on","off","~"]
        l.capitalizedIsType = false
        l.keysBeforeColon = true
        return l
    }()

    /// Текстовая сериализация Unity: `--- !u!114 &123` в заголовках,
    /// `{fileID: …, guid: …}` в ссылках. Переходы по ссылкам и структура
    /// сцены — в `UnityYAMLFile`, здесь только подсветка.
    static let unityYAML: LanguageSpec = {
        var l = yaml
        l.name = "Unity YAML"
        l.preprocessorPrefix = 0x25   // %YAML, %TAG
        l.attributePrefix = 0x21      // !u!114 — теги классов
        return l
    }()

    /// ShaderLab — обёртка `.shader`, внутри которой HLSL. Разделять их
    /// лексически незачем: блоки HLSL красятся тем же набором слов.
    static let shaderLab: LanguageSpec = {
        var l = hlsl
        l.name = "ShaderLab"
        l.keywords.formUnion([
            "Shader", "Properties", "SubShader", "Pass", "Tags", "LOD", "Name", "Fallback",
            "FallBack", "CustomEditor", "UsePass", "GrabPass", "Category", "Stencil",
            "Cull", "ZWrite", "ZTest", "ZClip", "Blend", "BlendOp", "ColorMask", "Offset",
            "AlphaToMask", "Conservative", "Lighting", "Fog", "Material", "SetTexture",
            "CGPROGRAM", "ENDCG", "CGINCLUDE", "HLSLPROGRAM", "ENDHLSL", "HLSLINCLUDE",
            "PackageRequirements", "Off", "On", "Back", "Front", "LEqual", "Less", "Greater",
            "GEqual", "Equal", "NotEqual", "Always", "Never", "One", "Zero", "SrcAlpha",
            "OneMinusSrcAlpha", "DstColor", "SrcColor", "OneMinusDstColor", "OneMinusSrcColor",
            "Ref", "Comp", "ReadMask", "WriteMask", "Replace", "Keep",
        ])
        l.typeKeywords.formUnion(["Range", "Color", "Vector", "Cube", "Int", "Float", "Integer", "CubeArray"])
        return l
    }()

    static let hlsl: LanguageSpec = {
        var l = LanguageSpec(name: "HLSL")
        l.lineComments = [LanguageSpec.s("//")]
        l.blockComment = (LanguageSpec.s("/*"), LanguageSpec.s("*/"))
        l.strings = [StringSpec(open: LanguageSpec.s("\""), close: LanguageSpec.s("\""), escapes: true, multiline: false)]
        l.preprocessorPrefix = 0x23
        l.keywords = ["break", "case", "cbuffer", "const", "continue", "default", "discard", "do",
            "else", "extern", "for", "groupshared", "if", "in", "inline", "inout", "out", "nointerpolation",
            "linear", "centroid", "noperspective", "sample", "precise", "return", "static", "struct",
            "switch", "tbuffer", "typedef", "uniform", "volatile", "while", "register", "packoffset",
            "unroll", "loop", "branch", "flatten", "numthreads", "row_major", "column_major"]
        l.constants = ["true", "false", "NULL"]
        var types: Set<String> = ["void", "bool", "int", "uint", "dword", "half", "float", "double",
            "fixed", "min16float", "min10float", "min16int", "min12int", "min16uint", "real",
            "sampler", "sampler1D", "sampler2D", "sampler3D", "samplerCUBE", "sampler2D_float",
            "sampler_state", "SamplerState", "SamplerComparisonState",
            "Texture1D", "Texture2D", "Texture3D", "TextureCube", "Texture2DArray", "TextureCubeArray",
            "Texture2DMS", "RWTexture2D", "RWTexture3D", "RWTexture2DArray", "Buffer", "RWBuffer",
            "StructuredBuffer", "RWStructuredBuffer", "ByteAddressBuffer", "RWByteAddressBuffer",
            "AppendStructuredBuffer", "ConsumeStructuredBuffer", "string", "vector", "matrix"]
        for base in ["bool", "int", "uint", "half", "float", "double", "fixed", "real", "min16float"] {
            for n in 1...4 {
                types.insert("\(base)\(n)")
                for m in 1...4 { types.insert("\(base)\(n)x\(m)") }
            }
        }
        l.typeKeywords = types
        l.capitalizedIsType = false   // макросы SRP: TEXTURE2D, SAMPLE_TEXTURE2D — не типы
        l.outline = .cFamily
        l.declarationKeywords = ["struct": .type, "cbuffer": .type, "tbuffer": .type]
        l.modifierKeywords = ["static", "inline", "uniform", "extern", "precise", "groupshared", "const"]
        return l
    }()

    static let toml: LanguageSpec = {
        var l = LanguageSpec(name: "TOML")
        l.lineComments = [LanguageSpec.s("#")]
        l.strings = [
            StringSpec(open: LanguageSpec.s("\"\"\""), close: LanguageSpec.s("\"\"\""), escapes: true, multiline: true),
            StringSpec(open: LanguageSpec.s("\""), close: LanguageSpec.s("\""), escapes: true, multiline: false),
            StringSpec(open: LanguageSpec.s("'"), close: LanguageSpec.s("'"), escapes: false, multiline: false),
        ]
        l.constants = ["true","false"]
        l.capitalizedIsType = false
        return l
    }()

    static let xml: LanguageSpec = {
        var l = LanguageSpec(name: "XML/HTML")
        l.blockComment = (LanguageSpec.s("<!--"), LanguageSpec.s("-->"))
        l.strings = [
            StringSpec(open: LanguageSpec.s("\""), close: LanguageSpec.s("\""), escapes: false, multiline: false),
            StringSpec(open: LanguageSpec.s("'"), close: LanguageSpec.s("'"), escapes: false, multiline: false),
        ]
        l.capitalizedIsType = false
        return l
    }()

    static let css: LanguageSpec = {
        var l = LanguageSpec(name: "CSS")
        l.blockComment = (LanguageSpec.s("/*"), LanguageSpec.s("*/"))
        l.lineComments = [LanguageSpec.s("//")]
        l.strings = [
            StringSpec(open: LanguageSpec.s("\""), close: LanguageSpec.s("\""), escapes: true, multiline: false),
            StringSpec(open: LanguageSpec.s("'"), close: LanguageSpec.s("'"), escapes: true, multiline: false),
        ]
        l.preprocessorPrefix = 0x40   // @media, @import
        l.capitalizedIsType = false
        return l
    }()

    static let sql: LanguageSpec = {
        var l = LanguageSpec(name: "SQL")
        l.lineComments = [LanguageSpec.s("--")]
        l.blockComment = (LanguageSpec.s("/*"), LanguageSpec.s("*/"))
        l.strings = [
            StringSpec(open: LanguageSpec.s("'"), close: LanguageSpec.s("'"), escapes: false, multiline: false),
            StringSpec(open: LanguageSpec.s("\""), close: LanguageSpec.s("\""), escapes: false, multiline: false),
        ]
        l.keywords = ["select","from","where","insert","into","values","update","set","delete","create","table",
            "alter","drop","index","view","join","inner","left","right","outer","full","on","group","by","order",
            "having","limit","offset","union","all","distinct","as","and","or","not","in","exists","between",
            "like","case","when","then","else","end","with","primary","key","foreign","references","constraint",
            "default","unique","check","cascade","returning","begin","commit","rollback","transaction"]
        l.constants = ["null","true","false"]
        l.capitalizedIsType = false
        l.outline = .keyword
        l.declarationKeywords = ["table": .type, "view": .type, "index": .field, "function": .method]
        return l
    }()

    static let markdown: LanguageSpec = {
        var l = LanguageSpec(name: "Markdown")
        l.strings = [StringSpec(open: LanguageSpec.s("`"), close: LanguageSpec.s("`"), escapes: false, multiline: false)]
        l.capitalizedIsType = false
        return l
    }()
}
