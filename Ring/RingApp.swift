import SwiftUI
import AppKit

@main
struct RingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // The menu bar item and its panel are managed by StatusController (AppKit), not a SwiftUI
    // scene. An app needs at least one scene, so this empty Settings scene stands in.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Created at launch (not when the menu first opens) so the account registers right away.
    let sip = SIPManager()
    private var statusController: StatusController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusController = StatusController(sip: sip)
    }

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
