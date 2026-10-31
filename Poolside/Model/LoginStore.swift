import Foundation
import Security

enum ConnectionMode: String, CaseIterable, Identifiable, Codable {
    case auto, local, remote
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto"
        case .local: return "Home WiFi"
        case .remote: return "Away"
        }
    }
}

struct SavedLogin: Codable, Equatable {
    var systemName: String
    var mode: ConnectionMode = .auto
    /// Last gateway address seen on the home network. Empty until we find it.
    var localHost: String = ""
    var localPort: UInt16 = 80

    /// "Pentair: 12-34-56" from either that or just "12-34-56".
    static func normalizedName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("pentair") { return trimmed }
        return "Pentair: \(trimmed.uppercased())"
    }

    var shortName: String {
        systemName.replacingOccurrences(of: "Pentair:", with: "").trimmingCharacters(in: .whitespaces)
    }
}

/// Sign-in details stay until Sign out. The password goes in the Keychain.
enum LoginStore {
    private static let defaultsKey = "poolside.login"
    private static let service = "Poolside"
    private static let account = "remote-password"

    static func load() -> SavedLogin? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(SavedLogin.self, from: data)
    }

    static func save(_ login: SavedLogin) {
        if let data = try? JSONEncoder().encode(login) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        setPassword("")
    }

    static func password() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    static func setPassword(_ value: String) {
        SecItemDelete(baseQuery as CFDictionary)
        guard !value.isEmpty else { return }
        var item = baseQuery
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}
