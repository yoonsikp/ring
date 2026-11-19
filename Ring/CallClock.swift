import Foundation

/// Ticks once a second during a call, for the menu bar timer. Kept separate from SIPManager so
/// only the menu bar label re-renders every second, not the whole popover.
@MainActor
final class CallClock: ObservableObject {
    @Published private(set) var elapsed: Int?   // seconds; nil when not in a call
    private var timer: Timer?
    private var since: Date?

    func start(since start: Date) {
        since = start
        elapsed = 0
        timer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        since = nil
        elapsed = nil
    }

    private func tick() {
        guard let since else { return }
        elapsed = max(0, Int(Date().timeIntervalSince(since)))
    }
}

/// m:ss under an hour, h:mm:ss from an hour on.
func formatCallDuration(_ seconds: Int) -> String {
    let s = max(0, seconds)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                     : String(format: "%d:%02d", s / 60, s % 60)
}
