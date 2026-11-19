import Foundation

/// The only audio codecs Ring will offer or accept. Everything else liblinphone ships is disabled.
enum Codec: String, CaseIterable, Identifiable {
    case pcmu = "PCMU", pcma = "PCMA", g722 = "G722", gsm = "GSM"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pcmu: return "PCMU (G.711 µ-law)"
        case .pcma: return "PCMA (G.711 A-law)"
        case .g722: return "G.722 (wideband)"
        case .gsm: return "GSM"
        }
    }
}

/// App preferences that don't affect the SIP registration. Stored in UserDefaults.
struct AudioSettings: Equatable {
    /// Software echo canceller. Needed on speakers; turn off with headphones (it can make audio choppy).
    var echoCancellation = true
    /// Play tones for keys the other side presses. Off by default; digits are shown either way.
    var playReceivedDTMF = false
    var enabledCodecs: Set<Codec> = Set(Codec.allCases)
    /// RFC 3389 comfort noise (CN payload). Off by default.
    var comfortNoise = false

    private enum Key {
        static let echoCancellation = "echoCancellation"
        static let playReceivedDTMF = "playReceivedDTMF"
        static let enabledCodecs = "enabledCodecs"
        static let comfortNoise = "comfortNoise"
    }

    static func load() -> AudioSettings {
        let d = UserDefaults.standard
        var s = AudioSettings()
        s.echoCancellation = d.object(forKey: Key.echoCancellation) as? Bool ?? true
        s.playReceivedDTMF = d.bool(forKey: Key.playReceivedDTMF)
        s.comfortNoise = d.bool(forKey: Key.comfortNoise)
        if let names = d.stringArray(forKey: Key.enabledCodecs) {
            let codecs = Set(names.compactMap(Codec.init(rawValue:)))
            if !codecs.isEmpty { s.enabledCodecs = codecs }
        }
        return s
    }

    func save() {
        let d = UserDefaults.standard
        d.set(echoCancellation, forKey: Key.echoCancellation)
        d.set(playReceivedDTMF, forKey: Key.playReceivedDTMF)
        d.set(comfortNoise, forKey: Key.comfortNoise)
        d.set(Codec.allCases.filter(enabledCodecs.contains).map(\.rawValue), forKey: Key.enabledCodecs)
    }
}
