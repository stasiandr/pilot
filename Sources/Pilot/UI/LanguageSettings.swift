import SwiftUI

/// Язык интерфейса: выбранный в настройках или, пока не выбран, системный.
///
/// Строки Pilot переключаются сразу: окно и меню перестраиваются. Штатные
/// части macOS — пункты «Правка» и «Окно», панель поиска, контекстное меню
/// текста — AppKit локализует при запуске по `AppleLanguages`, поэтому для
/// них выбор пишется туда же и доходит после перезапуска.
@MainActor
final class LanguageStore: ObservableObject {
    static let shared = LanguageStore()

    private static let key = "pilot.language"

    /// Выбор в настройках; `nil` — как в системе.
    @Published private(set) var choice: AppLanguage?
    /// Язык, на котором интерфейс сейчас.
    @Published private(set) var current: AppLanguage

    private init() {
        let saved = Self.savedChoice
        choice = saved
        current = Self.resolve(saved)
        Localization.current = current
    }

    /// До первого окна: строки меню и окна читаются уже на нужном языке.
    nonisolated static func applySaved() {
        Localization.current = resolve(savedChoice)
        launchLanguage = Localization.current
    }

    /// Язык, с которым Pilot запущен: штатные меню macOS остаются на нём
    /// до перезапуска.
    nonisolated(unsafe) private(set) static var launchLanguage = AppLanguage.ru

    var needsRestart: Bool { current != Self.launchLanguage }

    func select(_ choice: AppLanguage?) {
        guard choice != self.choice else { return }
        let defaults = UserDefaults.standard
        if let choice {
            defaults.set(choice.rawValue, forKey: Self.key)
            defaults.set([choice.rawValue], forKey: "AppleLanguages")
        } else {
            defaults.removeObject(forKey: Self.key)
            defaults.removeObject(forKey: "AppleLanguages")
        }
        self.choice = choice
        let language = Self.resolve(choice)
        Localization.current = language
        current = language
    }

    /// Какой язык значит «как в системе» — для подписи в настройках.
    var systemLanguage: AppLanguage { Self.resolve(nil) }

    nonisolated private static var savedChoice: AppLanguage? {
        UserDefaults.standard.string(forKey: key).flatMap(AppLanguage.init(rawValue:))
    }

    /// Языки системы читаются из общего домена: в своём Pilot сам пишет
    /// `AppleLanguages`, когда язык выбран явно.
    nonisolated private static func resolve(_ choice: AppLanguage?) -> AppLanguage {
        if let choice { return choice }
        let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
        let system = global?["AppleLanguages"] as? [String] ?? Locale.preferredLanguages
        return AppLanguage.preferred(from: system)
    }
}

/// Настройки → Общие.
struct GeneralSettingsView: View {
    @ObservedObject var language: LanguageStore

    var body: some View {
        Form {
            Picker(L("Язык интерфейса"), selection: Binding(
                get: { language.choice },
                set: { language.select($0) }
            )) {
                Text(L("Как в системе — \(language.systemLanguage.nativeName)")).tag(AppLanguage?.none)
                Divider()
                ForEach(AppLanguage.allCases) { item in
                    Text(item.nativeName).tag(AppLanguage?.some(item))
                }
            }
            if language.needsRestart {
                Text(L("Системные меню и диалоги macOS сменят язык после перезапуска Pilot."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            UpdateSettingsSection(updater: Updater.shared)
        }
        .formStyle(.grouped)
        .frame(width: 640, height: 300)
    }
}

/// Обновления: версия, автопроверка и проверка прямо сейчас.
private struct UpdateSettingsSection: View {
    @ObservedObject var updater: Updater

    var body: some View {
        Section(L("Обновления")) {
            Toggle(L("Проверять обновления автоматически"), isOn: $updater.checksAutomatically)
            HStack {
                Text(L("Версия \(updater.current.description)"))
                    .foregroundStyle(.secondary)
                Spacer()
                if updater.isChecking { ProgressView().controlSize(.small) }
                Button(L("Проверить сейчас")) { updater.checkNow() }
                    .disabled(updater.isChecking)
            }
        }
    }
}
