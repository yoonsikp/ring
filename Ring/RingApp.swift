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
            StatusIcon(sip: appDelegate.sip)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu bar icon. Its own view so it re-renders when the SIP state changes.
private struct StatusIcon: View {
    @ObservedObject var sip: SIPManager

    var body: some View {
        Image(systemName: sip.statusSymbol)
            .accessibilityLabel(sip.statusText)
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
        switch registration {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .disconnected: return settings.isComplete ? "Disconnected" : "Not configured"
        case .failed(let why): return "Failed: \(why)"
        }
    }
}
