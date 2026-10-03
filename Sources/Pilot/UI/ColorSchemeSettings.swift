import AppKit
import SwiftUI

/// Настройки → Оформление: схемы карточками, в каждой — кусочек кода
/// в её цветах. Клик — и схема применяется сразу, во всём окне.
struct ColorSchemeSettingsView: View {
    private let store = ThemeStore.shared
    private let columns = [GridItem(.adaptive(minimum: 190), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(EditorScheme.Family.allCases, id: \.self) { family in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(family.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(EditorScheme.all.filter { $0.family == family }) { scheme in
                                SchemeCard(scheme: scheme, isSelected: store.scheme == scheme)
                                    .onTapGesture { store.select(scheme.id) }
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .frame(width: 640, height: 580)
    }
}

private struct SchemeCard: View {
    let scheme: EditorScheme
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sample
                .font(.custom("HackNFM-Regular", size: 11).monospaced())
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(nsColor: scheme.p.base))
            HStack(spacing: 6) {
                Text(scheme.name).font(.system(size: 12, weight: .medium))
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: isSelected ? 2 : 1))
        .contentShape(Rectangle())
        .help(scheme.isDark ? L("Тёмная схема") : L("Светлая схема"))
    }

    /// Строчки на все главные роли: комментарий, ключевое слово, тип,
    /// атрибут, число, метод, строка. `int` и `void` — как в редакторе:
    /// там они типы, кроме схем, которые красят их ключевыми словами.
    private var sample: Text {
        let s = scheme.syntax
        func t(_ text: String, _ color: NSColor) -> Text { Text(text).foregroundColor(Color(nsColor: color)) }
        let typeKeyword = s.typeKeyword ?? s.type
        let head = t("// Игрок\n", s.comment)
            + t("class ", s.keyword) + t("Player", s.type) + t(" {\n", s.punctuation)
        let field = t("  [", s.punctuation) + t("Header", s.attribute) + t("] ", s.punctuation)
            + t("int ", typeKeyword) + t("hp", s.field) + t(" = ", s.operatorTok) + t("5", s.number)
            + t(";\n", s.punctuation)
        let method = t("  void ", typeKeyword) + t("Run", s.function) + t("() {\n", s.punctuation)
            + t("    if ", s.controlKeyword ?? s.keyword) + t("(", s.punctuation) + t("hp", s.field)
            + t(" > ", s.operatorTok) + t("0", s.number) + t(") ", s.punctuation)
            + t("Say", s.function) + t("(", s.punctuation) + t("\"hi\"", s.string) + t(");\n", s.punctuation)
        return head + field + method + t("  }\n}", s.punctuation)
    }
}
