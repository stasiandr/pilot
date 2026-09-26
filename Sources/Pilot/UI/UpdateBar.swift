import SwiftUI

/// Плашка над редактором: вышла новая версия Pilot. Одна на все окна —
/// состояние общее (`Updater.shared`), поэтому и прогресс скачивания виден
/// в каждом.
struct UpdateBar: View {
    @ObservedObject var updater: Updater

    var body: some View {
        if updater.state != .idle {
            HStack(spacing: 10) {
                icon
                message
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                actions
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: Theme.chromeBackground))
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color(nsColor: Theme.separator)).frame(height: 1)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch updater.state {
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(nsColor: Theme.diagnosticWarning))
        case .installed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color(nsColor: Theme.gitAdded))
        default:
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(Color.accentColor)
        }
    }

    @ViewBuilder
    private var message: some View {
        switch updater.state {
        case .idle:
            EmptyView()
        case .available(let r):
            Text(L("Доступна новая версия Pilot \(r.version.description) — у вас \(updater.current.description)"))
        case .downloading(let r, _):
            Text(L("Скачиваю Pilot \(r.version.description)…"))
        case .installing(let r):
            Text(L("Устанавливаю Pilot \(r.version.description)…"))
        case .installed(let r):
            Text(L("Pilot \(r.version.description) установлен — перезапустите, чтобы перейти на него"))
        case .failed(_, let why):
            Text(L("Не удалось обновить: \(why)"))
                .help(why)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch updater.state {
        case .idle:
            EmptyView()
        case .available:
            Button(L("Что нового")) { updater.openReleasePage() }
                .buttonStyle(.link)
                .controlSize(.small)
            if let blocker = updater.installBlocker {
                Button(L("Скачать")) { updater.openReleasePage() }
                    .controlSize(.small)
                    .help(blocker)
            } else {
                Button(L("Обновить сейчас")) { updater.install() }
                    .controlSize(.small)
            }
            dismiss
        case .downloading(_, let fraction):
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .frame(width: 140)
        case .installing:
            ProgressView().controlSize(.small)
        case .installed:
            Button(L("Перезапустить")) { updater.relaunch() }
                .controlSize(.small)
        case .failed:
            Button(L("Скачать вручную")) { updater.openReleasePage() }
                .controlSize(.small)
            Button(L("Повторить")) { updater.install() }
                .controlSize(.small)
            dismiss
        }
    }

    private var dismiss: some View {
        Button { updater.skip() } label: {
            Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(L("Не напоминать об этой версии"))
    }
}
