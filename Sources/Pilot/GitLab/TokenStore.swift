import Foundation
import Security

/// Токены GitLab в связке ключей macOS — по одному на хост. В UserDefaults
/// и в файлы токен не попадает никогда.
///
/// Приложение подписано ad-hoc, и после каждой пересборки macOS считает его
/// новым: при первом чтении токена спросит разрешение («Всегда разрешать»).
enum TokenStore {
    private static let service = "dev.local.pilot.gitlab"

    private static func query(host: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: host]
    }

    static func token(for host: String) -> String? {
        var request = query(host: host)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String, for host: String) throws {
        let data = Data(token.utf8)
        let status = SecItemUpdate(query(host: host) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(host: host)
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Pilot — GitLab \(host)"
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    static func delete(host: String) {
        SecItemDelete(query(host: host) as CFDictionary)
    }

    struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            let text = SecCopyErrorMessageString(status, nil) as String? ?? "код \(status)"
            return "Не удалось сохранить токен в связке ключей: \(text)"
        }
    }
}
