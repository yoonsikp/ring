import SwiftUI
import AppKit

@main
struct RingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(appDelegate.sip)
        } label: {
            StatusIcon(sip: appDelegate.sip, clock: appDelegate.sip.clock)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu bar icon. Its own view so it re-renders when the SIP state changes.
private struct StatusIcon: View {
    @ObservedObject var sip: SIPManager
    @ObservedObject var clock: CallClock

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: Self.image(for: sip.statusSymbol))
            // Call duration while in a call: m:ss, or h:mm:ss after an hour.
            if let elapsed = clock.elapsed {
                Text(formatCallDuration(elapsed)).monospacedDigit()
            }
        }
        .accessibilityLabel(sip.statusText)
        .transaction { $0.animation = nil } // never animate the status item
    }

    /// Every state's symbol drawn centred on the same fixed canvas, so the status item
    /// never changes size (the SF Symbols for each state have different widths).
    private static var cache: [String: NSImage] = [:]
    private static let canvas = NSSize(width: 20, height: 16)

    private static func image(for name: String) -> NSImage {
        if let cached = cache[name] { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else { return NSImage(size: canvas) }
        let image = NSImage(size: canvas, flipped: false) { rect in
            let s = symbol.size
            let scale = min(1, rect.width / s.width, rect.height / s.height)
            let w = s.width * scale, h = s.height * scale
            symbol.draw(in: NSRect(x: (rect.width - w) / 2, y: (rect.height - h) / 2, width: w, height: h))
            return true
        }
        image.isTemplate = true // adapts to light/dark menu bar like a normal icon
        cache[name] = image
        return image
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Created at launch (not when the menu first opens) so the account registers right away.
    let sip = SIPManager()

    func applicationWillTerminate(_ notification: Notification) {
        sip.shutdown()
    }
}

extension SIPManager {
    /// Menu bar icon: tells you connected / disconnected at a glance, and call state.
    var statusSymbol: String {
        switch callPhase {
        case .incoming: return "phone.arrow.down.left.fill"
        case .outgoing: return "phone.arrow.up.right.fill"
        case .active: return "waveform.circle.fill"
        case .idle: break
        }
        switch registration {
        case .connected: return "phone.fill"
        case .connecting: return "phone"
        case .disconnected, .failed: return "phone.down"
        }
    }

    var statusText: String {
        if reconnectingAfterWake { return "Reconnecting…" }
        if !networkReachable && wantsConnection && settings.isComplete { return "No network" }
        switch registration {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .disconnected: return settings.isComplete ? "Disconnected" : "Not configured"
        case .failed(let why): return why
        }
    }
}
