#!/usr/bin/env python3
"""Встроенные раскладки Rider для импорта настроек.

В экспорте Rider своя раскладка хранит только отличия от встроенной, а
встроенные лежат внутри Rider.app. Скрипт берёт их из intellij-community
(Apache 2.0), оставляет действия, которые Pilot умеет сопоставить (они
перечислены в RiderImport.actions(for:)), и пишет
Sources/Pilot/Model/RiderBundledKeymaps.swift.

    bin/rider-keymaps.py [коммит intellij-community]
"""
import re
import sys
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
COMMIT = sys.argv[1] if len(sys.argv) > 1 else "2614de3ca2557d037f88afac9c08169357f70b84"
FILES = [
    "platform/platform-resources/src/keymaps/$default.xml",
    "platform/platform-resources/src/keymaps/Mac OS X.xml",
    "platform/platform-resources/src/keymaps/Mac OS X 10.5+.xml",
    "plugins/keymaps/vscode-keymap/resources/keymaps/VSCode OSX.xml",
]

source = (ROOT / "Sources/Pilot/Model/RiderImport.swift").read_text()
block = source[source.index("static func actions(for"):source.index("static let alwaysOn")]
wanted = set(re.findall(r'"([A-Z][A-Za-z]+)"', block))

out = []
for path in FILES:
    url = f"https://raw.githubusercontent.com/JetBrains/intellij-community/{COMMIT}/{urllib.parse.quote(path)}"
    root = ET.fromstring(urllib.request.urlopen(url).read())
    out.append("keymap\t" + root.get("name") + ("\t" + root.get("parent") if root.get("parent") else ""))
    for action in root.findall("action"):
        if action.get("id") not in wanted:
            continue
        strokes = []
        for s in action.findall("keyboard-shortcut"):
            second = s.get("second-keystroke")
            strokes.append(s.get("first-keystroke") + (", " + second if second else ""))
        out.append("\t".join([action.get("id")] + strokes))

body = "\n".join(out)
(ROOT / "Sources/Pilot/Model/RiderBundledKeymaps.swift").write_text(f'''import Foundation

/// Встроенные раскладки Rider — только действия, которые Pilot сопоставляет
/// своим командам. Собрано `bin/rider-keymaps.py` из intellij-community
/// {COMMIT[:12]} (Apache 2.0); руками не правится.
///
/// Строка `keymap<TAB>имя<TAB>родитель` открывает раскладку, дальше
/// `действие<TAB>сочетание<TAB>…`; у аккорда второе нажатие через запятую.
/// Действие без сочетаний — «в этой раскладке без сочетания».
enum RiderBundledKeymaps {{
    static let all = parse(table)

    static func parse(_ text: String) -> RiderKeymaps {{
        var keymaps: [String: RiderKeymap] = [:]
        var current: RiderKeymap?
        for line in text.split(separator: "\\n") {{
            let fields = line.split(separator: "\\t", omittingEmptySubsequences: false).map(String.init)
            if fields[0] == "keymap" {{
                if let done = current {{ keymaps[done.name] = done }}
                current = RiderKeymap(name: fields[1], parent: fields.count > 2 ? fields[2] : nil, actions: [:])
            }} else {{
                current?.actions[fields[0]] = fields.dropFirst().map {{ stroke in
                    let parts = stroke.components(separatedBy: ", ")
                    return RiderKeystroke(first: parts[0], second: parts.count > 1 ? parts[1] : nil)
                }}
            }}
        }}
        if let done = current {{ keymaps[done.name] = done }}
        return RiderKeymaps(keymaps: keymaps)
    }}

    private static let table = """
{body}
"""
}}
''')
print(f"{len(out)} строк, действий в списке: {len(wanted)}")
