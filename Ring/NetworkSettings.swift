import Foundation

/// IPv6 and NAT traversal (STUN / ICE / TURN). Stored in UserDefaults; TURN password in the Keychain.
struct NetworkSettings: Equatable {
    var ipv6 = true
    /// STUN/TURN server as host[:port]. Empty = no STUN.
    var stunServer = ""
    var ice = false
    var turn = false
    var turnUsername = ""
    var turnPassword = ""

    var hasServer: Bool { !stunServer.trimmingCharacters(in: .whitespaces).isEmpty }

    private enum Key {
        static let ipv6 = "ipv6", stunServer = "stunServer", ice = "ice", turn = "turn", turnUsername = "turnUsername"
    }

    static func load() -> NetworkSettings {
        let d = UserDefaults.standard
        var s = NetworkSettings()
        s.ipv6 = d.object(forKey: Key.ipv6) as? Bool ?? true
        s.stunServer = d.string(forKey: Key.stunServer) ?? ""
        s.ice = d.bool(forKey: Key.ice)
        s.turn = d.bool(forKey: Key.turn)
        s.turnUsername = d.string(forKey: Key.turnUsername) ?? ""
        s.turnPassword = Keychain.read(Keychain.turnPassword) ?? ""
        return s
    }

    func save() {
        let d = UserDefaults.standard
        d.set(ipv6, forKey: Key.ipv6)
        d.set(stunServer.trimmingCharacters(in: .whitespaces), forKey: Key.stunServer)
        d.set(ice, forKey: Key.ice)
        d.set(turn, forKey: Key.turn)
        d.set(turnUsername, forKey: Key.turnUsername)
        if turnPassword.isEmpty { Keychain.delete(Keychain.turnPassword) }
        else { Keychain.write(turnPassword, Keychain.turnPassword) }
    }
}
