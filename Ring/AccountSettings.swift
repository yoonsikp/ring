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
    /// Software echo canceller. Needed on speakers; turn off with headphones (it can make audio choppy).
    var echoCancellation: Bool = true
    /// Play tones for keys the other side presses. Off by default; digits are shown either way.
    var playReceivedDTMF: Bool = false

    var isComplete: Bool { !sipAddress.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty }

    /// SIP address normalised to always start with "sip:".
    var normalizedAddress: String {
        let s = sipAddress.trimmingCharacters(in: .whitespaces)
        if s.lowercased().hasPrefix("sip:") || s.lowercased().hasPrefix("sips:") { return s }
        return "sip:" + s
    }

    private enum Key {
        static let sipAddress = "sipAddress", username = "username", server = "server", useTLS = "useTLS"
        static let echoCancellation = "echoCancellation"
        static let playReceivedDTMF = "playReceivedDTMF"
    }

    static func load() -> AccountSettings {
        let d = UserDefaults.standard
        var s = AccountSettings()
        s.sipAddress = d.string(forKey: Key.sipAddress) ?? ""
        s.username = d.string(forKey: Key.username) ?? ""
        s.server = d.string(forKey: Key.server) ?? ""
        s.useTLS = d.object(forKey: Key.useTLS) as? Bool ?? true
        s.echoCancellation = d.object(forKey: Key.echoCancellation) as? Bool ?? true
        s.playReceivedDTMF = d.bool(forKey: Key.playReceivedDTMF)
        s.password = Keychain.read() ?? ""
        return s
    }

    func save() {
        let d = UserDefaults.standard
        d.set(sipAddress, forKey: Key.sipAddress)
        d.set(username, forKey: Key.username)
        d.set(server, forKey: Key.server)
        d.set(useTLS, forKey: Key.useTLS)
        d.set(echoCancellation, forKey: Key.echoCancellation)
        d.set(playReceivedDTMF, forKey: Key.playReceivedDTMF)
        if password.isEmpty { Keychain.delete() } else { Keychain.write(password) }
    }
}

enum Keychain {
    private static let service = "com.yoonsikp.Ring"
    private static let account = "sip-password"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read() -> String? {
        var q = baseQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String) {
        let data = Data(value.utf8)
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = baseQuery
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(q as CFDictionary, nil)
        }
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
