import SwiftUI

/// Настройки → Copilot: включить, войти через GitHub, увидеть, что с ним.
struct CopilotSettingsView: View {
    @ObservedObject var copilot: CopilotService

    var body: some View {
        Form {
            Toggle(L("Подсказки Copilot в коде"), isOn: Binding(
                get: { copilot.isEnabled },
                set: { copilot.isEnabled = $0 }))
            Text(L("Серый текст у курсора: Tab — принять, Esc — убрать. Нужна подписка GitHub Copilot."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if copilot.isEnabled {
                Section { status }
            }
        }
        .formStyle(.grouped)
        .frame(width: 640, height: 300)
    }

    @ViewBuilder
    private var status: some View {
        switch copilot.status {
        case .off:
            EmptyView()
        case .installing(let fraction):
            LabeledContent(L("Скачиваю сервер Copilot")) {
                ProgressView(value: fraction).frame(width: 200)
            }
        case .starting:
            LabeledContent(L("Запускается")) { ProgressView().controlSize(.small) }
        case .signedOut:
            LabeledContent(L("Не выполнен вход в GitHub")) {
                Button(L("Войти через GitHub…")) { copilot.signIn() }
            }
        case .signingIn(let code, _):
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Введите код на странице GitHub — он уже в буфере обмена:"))
                Text(code)
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                HStack {
                    Button(L("Скопировать код и открыть GitHub")) { copilot.openVerificationPage() }
                    ProgressView().controlSize(.small)
                    Text(L("Жду подтверждения…")).foregroundStyle(.secondary)
                }
            }
        case .ready(let user):
            LabeledContent(user.map { L("Вход выполнен: \($0)") } ?? L("Вход выполнен")) {
                Button(L("Выйти")) { copilot.signOut() }
            }
        case .failed(let why):
            VStack(alignment: .leading, spacing: 8) {
                Text(why).foregroundStyle(.orange)
                Button(L("Повторить")) {
                    copilot.isEnabled = false
                    copilot.isEnabled = true
                }
            }
        }
    }
}
