import SwiftUI

/// Настройка строки под редактором: что показывать и в каком порядке.
/// Перетаскиванием — порядок, галочкой — показать или спрятать.
/// «Растяжка» делит строку на левую и правую половины.
struct StatusBarCustomizer: View {
    @AppStorage(StatusBarLayout.key) private var stored = StatusBarLayout.defaultText

    private var items: [StatusBarItem] { StatusBarLayout.decode(stored) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Строка под редактором")).font(.headline)
            Text(L("Перетащите, чтобы поменять порядок. Всё, что до растяжки, — слева, после — справа."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List {
                Section(L("Показаны")) {
                    ForEach(items, id: \.self) { item in
                        row(item, shown: true)
                    }
                    .onMove { from, to in
                        var list = items
                        list.move(fromOffsets: from, toOffset: to)
                        stored = StatusBarLayout.encode(list)
                    }
                }
                let hidden = StatusBarLayout.hidden(items)
                if !hidden.isEmpty {
                    Section(L("Скрыты")) {
                        ForEach(hidden, id: \.self) { item in
                            row(item, shown: false)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 300)
            HStack {
                Spacer()
                Button(L("Как было")) { stored = StatusBarLayout.defaultText }
                    .disabled(items == StatusBarLayout.defaults)
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private func row(_ item: StatusBarItem, shown: Bool) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { shown }, set: { set(item, shown: $0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
            Image(systemName: item.icon).frame(width: 18).foregroundStyle(.secondary)
            Text(item.title).foregroundStyle(shown ? .primary : .secondary)
            Spacer()
            if shown { Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary) }
        }
        .font(.system(size: 12))
    }

    private func set(_ item: StatusBarItem, shown: Bool) {
        var list = items
        if shown {
            // Вернувшийся — на своё место из порядка по умолчанию.
            let order = StatusBarLayout.defaults
            let rank = order.firstIndex(of: item) ?? order.count
            let index = list.firstIndex { (order.firstIndex(of: $0) ?? order.count) > rank } ?? list.count
            list.insert(item, at: index)
        } else {
            list.removeAll { $0 == item }
        }
        stored = StatusBarLayout.encode(list)
    }
}
