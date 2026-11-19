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
        // The menu bar label ignores SwiftUI font modifiers, so the call duration is drawn
        // into the image with a monospaced-digit font to keep its width steady.
        Image(nsImage: clock.elapsed.map { Self.image(for: sip.statusSymbol, time: formatCallDuration($0)) }
                       ?? Self.image(for: sip.statusSymbol))
        .accessibilityLabel(sip.statusText)
        .transaction { $0.animation = nil } // never animate the status item
    }

    /// Every state's symbol drawn centred on the same fixed canvas, so the status item
    /// never changes size (the SF Symbols for each state have different widths).
    private static var cache: [String: NSImage] = [:]
    private static let canvas = NSSize(width: 20, height: 16)

    /// Icon followed by the call duration (m:ss / h:mm:ss), as one template image.
    private static func image(for name: String, time: String) -> NSImage {
        let icon = image(for: name)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let text = NSAttributedString(string: time, attributes: [.font: font, .foregroundColor: NSColor.black])
        let textSize = text.size()
        let gap: CGFloat = 4
        let size = NSSize(width: ceil(canvas.width + gap + textSize.width),
                          height: max(canvas.height, ceil(textSize.height)))
        let result = NSImage(size: size, flipped: false) { rect in
            icon.draw(in: NSRect(x: 0, y: (rect.height - canvas.height) / 2,
                                 width: canvas.width, height: canvas.height))
            text.draw(at: NSPoint(x: canvas.width + gap, y: (rect.height - textSize.height) / 2))
            return true
        }
        result.isTemplate = true // tinted for light/dark menu bar like the icon
        return result
    }

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
