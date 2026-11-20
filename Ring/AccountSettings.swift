import Foundation
import Security

/// The one SIP account. Non-secret fields live in UserDefaults; the password lives in the Keychain.
struct AccountSettings: Equatable {
    /// e.g. "sip:alice@example.com"
    var sipAddress: String = ""
    /// Auth username; if empty, the user part of the SIP address is used.
    var username: String = ""
    var password: String = ""
    /// Optional registrar/proxy host[:port]; if empty, the SIP address's domain is used.
    var server: String = ""
    var useTLS: Bool = true
    /// Country for formatting phone numbers (two-letter code), "" = automatic from the Mac's region.
    /// Display only: changing it doesn't affect the SIP registration.
    var phoneRegion: String = ""
    /// Menu bar icon: true = macOS draws the SF Symbol (crisp, width varies by state);
    /// false = Ring draws it on a fixed-width canvas. Display only.
    var systemMenuBarIcon: Bool = true

    var isComplete: Bool { !sipAddress.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty }

    /// SIP address normalised to always start with "sip:".
    var normalizedAddress: String {
        let s = sipAddress.trimmingCharacters(in: .whitespaces)
        if s.lowercased().hasPrefix("sip:") || s.lowercased().hasPrefix("sips:") { return s }
        return "sip:" + s
    }

    private enum Key {
        static let sipAddress = "sipAddress", username = "username", server = "server", useTLS = "useTLS"
        static let phoneRegion = "phoneRegion"
        static let systemMenuBarIcon = "systemMenuBarIcon"
    }

    static func load() -> AccountSettings {
        let d = UserDefaults.standard
        var s = AccountSettings()
        s.sipAddress = d.string(forKey: Key.sipAddress) ?? ""
        s.username = d.string(forKey: Key.username) ?? ""
        s.server = d.string(forKey: Key.server) ?? ""
        s.useTLS = d.object(forKey: Key.useTLS) as? Bool ?? true
        s.phoneRegion = d.string(forKey: Key.phoneRegion) ?? ""
        s.systemMenuBarIcon = d.object(forKey: Key.systemMenuBarIcon) as? Bool ?? true
        s.password = Keychain.read() ?? ""
        return s
    }

    func save() {
        let d = UserDefaults.standard
        d.set(sipAddress, forKey: Key.sipAddress)
        d.set(username, forKey: Key.username)
        d.set(server, forKey: Key.server)
        d.set(useTLS, forKey: Key.useTLS)
        d.set(phoneRegion, forKey: Key.phoneRegion)
        d.set(systemMenuBarIcon, forKey: Key.systemMenuBarIcon)
        if password.isEmpty { Keychain.delete() } else { Keychain.write(password) }
    }
}

enum Keychain {
    private static let service = "com.yoonsikp.Ring"
    /// Item names: the SIP password (the original, default item) and the TURN password.
    static let sipPassword = "sip-password"
    static let turnPassword = "turn-password"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read(_ account: String = sipPassword) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, _ account: String = sipPassword) {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(account)
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(q as CFDictionary, nil)
        }
    }

    static func delete(_ account: String = sipPassword) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
