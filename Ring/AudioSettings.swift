import Foundation

/// The only audio codecs Ring will offer or accept. Everything else liblinphone ships is disabled.
enum Codec: String, CaseIterable, Identifiable {
    case g711 = "G711", g722 = "G722", gsm = "GSM"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .g711: return "G.711 (PCMU / PCMA)"
        case .g722: return "G.722 (wideband)"
        case .gsm: return "GSM"
        }
    }

    /// liblinphone payload mime types this toggle controls.
    var mimeTypes: [String] {
        switch self {
        case .g711: return ["PCMU", "PCMA"]
        case .g722: return ["G722"]
        case .gsm: return ["GSM"]
        }
    }
}

/// App preferences that don't affect the SIP registration. Stored in UserDefaults.
struct AudioSettings: Equatable {
    /// Software echo canceller. Needed on speakers; turn off with headphones (it can make audio choppy).
    var echoCancellation = true
    var enabledCodecs: Set<Codec> = Set(Codec.allCases)
    /// Adaptive jitter buffer (liblinphone default). When off, a fixed buffer of `jitterBufferMs` is used.
    var adaptiveJitterBuffer = true
    var jitterBufferMs = 60

    static let jitterBufferRange = 20...500

    private enum Key {
        static let echoCancellation = "echoCancellation"
        static let enabledCodecs = "enabledCodecs"
        static let adaptiveJitterBuffer = "adaptiveJitterBuffer"
        static let jitterBufferMs = "jitterBufferMs"
    }

    static func load() -> AudioSettings {
        let d = UserDefaults.standard
        var s = AudioSettings()
        s.echoCancellation = d.object(forKey: Key.echoCancellation) as? Bool ?? true
        s.adaptiveJitterBuffer = d.object(forKey: Key.adaptiveJitterBuffer) as? Bool ?? true
        if let ms = d.object(forKey: Key.jitterBufferMs) as? Int {
            s.jitterBufferMs = min(max(ms, jitterBufferRange.lowerBound), jitterBufferRange.upperBound)
        }
        if let names = d.stringArray(forKey: Key.enabledCodecs) {
            // Older versions stored PCMU and PCMA separately.
            let codecs = Set(names.map { $0 == "PCMU" || $0 == "PCMA" ? "G711" : $0 }
                                  .compactMap(Codec.init(rawValue:)))
            if !codecs.isEmpty { s.enabledCodecs = codecs }
        }
        return s
    }

    func save() {
        let d = UserDefaults.standard
        d.set(echoCancellation, forKey: Key.echoCancellation)
        d.set(adaptiveJitterBuffer, forKey: Key.adaptiveJitterBuffer)
        d.set(jitterBufferMs, forKey: Key.jitterBufferMs)
        d.set(Codec.allCases.filter(enabledCodecs.contains).map(\.rawValue), forKey: Key.enabledCodecs)
        for removed in ["playReceivedDTMF", "logging"] { d.removeObject(forKey: removed) } // old settings
    }
}
