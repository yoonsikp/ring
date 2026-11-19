import AppKit
import Combine
import SwiftUI

/// Tells the SwiftUI content when the panel opens and closes.
@MainActor
final class PanelState: ObservableObject {
    /// Bumped every time the panel opens (the home page focuses the number field).
    @Published private(set) var openCount = 0
    /// Bumped every time the panel closes (the content goes back to the home page).
    @Published private(set) var closeCount = 0

    fileprivate func didOpen() { openCount += 1 }
    fileprivate func didClose() { closeCount += 1 }
}

/// Owns the menu bar item and the panel that drops down from it.
///
/// Replaces SwiftUI's MenuBarExtra, which treated clicks on the padding around the icon as
/// "outside", closing and immediately reopening the panel. Here the whole status item toggles.
@MainActor
final class StatusController: NSObject {
    private let sip: SIPManager
    private let panelState = PanelState()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel: DropdownPanel
    private let hostingView: NSHostingView<AnyView>
    private var contentSize = NSSize(width: 280, height: 200)
    private var subscriptions = Set<AnyCancellable>()
    private var outsideClickMonitor: Any?
    private var escapeMonitor: Any?

    init(sip: SIPManager) {
        self.sip = sip

        panel = DropdownPanel(contentRect: NSRect(origin: .zero, size: contentSize),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: true)

        // Placeholder; replaced below once `self` can be captured for size reports.
        hostingView = NSHostingView(rootView: AnyView(EmptyView()))
        super.init()

        let root = PanelRoot(onSize: { [weak self] size in self?.contentDidResize(size) })
            .environmentObject(sip)
            .environmentObject(panelState)
        hostingView.rootView = AnyView(root)
        // We size and place the panel ourselves (top-anchored under the icon); don't let the
        // hosting view's size constraints resize the window from its bottom edge.
        hostingView.sizingOptions = []

        configurePanel()
        configureStatusItem()
        observeState()
    }

    // MARK: Setup

    private func configurePanel() {
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .utilityWindow

        // Rounded, translucent background like a system menu bar window.
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true

        hostingView.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: background.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePanel)
        _ = button.sendAction(on: [.leftMouseDown, .rightMouseDown]) // respond on press, like system items
        button.imagePosition = .imageOnly
        updateStatusItem()
    }

    /// Redraw the icon whenever anything it shows changes. @Published fires before the new value
    /// is stored, so the redraw is deferred to the next main-queue turn.
    private func observeState() {
        let triggers: [AnyPublisher<Void, Never>] = [
            sip.$registration.map { _ in () }.eraseToAnyPublisher(),
            sip.$callPhase.map { _ in () }.eraseToAnyPublisher(),
            sip.$reconnectingAfterWake.map { _ in () }.eraseToAnyPublisher(),
            sip.$networkReachable.map { _ in () }.eraseToAnyPublisher(),
            sip.$wantsConnection.map { _ in () }.eraseToAnyPublisher(),
            sip.clock.$elapsed.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(triggers)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.updateStatusItem() }
            .store(in: &subscriptions)
    }

    // MARK: Status item

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        if let elapsed = sip.clock.elapsed {
            button.image = StatusIcon.image(for: sip.statusSymbol, time: formatCallDuration(elapsed))
        } else {
            button.image = StatusIcon.image(for: sip.statusSymbol)
        }
        button.toolTip = sip.statusText
        button.setAccessibilityLabel("Ring: \(sip.statusText)")
    }

    // MARK: Panel

    @objc private func togglePanel() {
        if panel.isVisible { closePanel() } else { openPanel() }
    }

    private func openPanel() {
        positionPanel()
        panel.orderFrontRegardless()
        panel.makeKey()
        statusItem.button?.highlight(true)
        panelState.didOpen()

        // Clicks in other apps, the desktop or other menu bar items close the panel. (Global
        // monitors never see clicks on our own status item, which toggles via its action.)
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePanel() }
        }
        // Escape closes it.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event } // Escape
            MainActor.assumeIsolated { self?.closePanel() }
            return nil
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(spaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    }

    private func closePanel() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m) }
        if let m = escapeMonitor { NSEvent.removeMonitor(m) }
        outsideClickMonitor = nil
        escapeMonitor = nil
        NSWorkspace.shared.notificationCenter.removeObserver(
            self, name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        panelState.didClose()
    }

    @objc private func spaceChanged() { closePanel() }

    /// SwiftUI reports its natural size; resize the panel, keeping its top edge under the icon.
    private func contentDidResize(_ size: NSSize) {
        let rounded = NSSize(width: ceil(size.width), height: ceil(size.height))
        guard rounded != contentSize, rounded.width > 0, rounded.height > 0 else { return }
        contentSize = rounded
        if panel.isVisible { positionPanel() }
    }

    private func positionPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screenFrame = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? buttonFrame

        var x = buttonFrame.midX - contentSize.width / 2
        x = min(max(x, screenFrame.minX + 8), screenFrame.maxX - contentSize.width - 8)
        let top = buttonFrame.minY - 6
        panel.setFrame(NSRect(x: x, y: top - contentSize.height,
                              width: contentSize.width, height: contentSize.height),
                       display: true)
        panel.invalidateShadow()
    }
}

// MARK: - Panel window

/// Borderless, non-activating panel that can still take keyboard focus (for the text fields),
/// like Spotlight.
private final class DropdownPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Ring has no Edit menu while it's in the background, so handle the usual editing
    /// shortcuts (cut/copy/paste/select all/undo) here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command || flags == [.command, .shift],
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        let action: Selector?
        switch (key, flags.contains(.shift)) {
        case ("x", false): action = #selector(NSText.cut(_:))
        case ("c", false): action = #selector(NSText.copy(_:))
        case ("v", false): action = #selector(NSText.paste(_:))
        case ("a", false): action = #selector(NSText.selectAll(_:))
        case ("z", false): action = Selector(("undo:"))
        case ("z", true): action = Selector(("redo:"))
        default: action = nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - SwiftUI root

/// Hosts MenuView and reports its natural size so the panel can fit it.
private struct PanelRoot: View {
    let onSize: (NSSize) -> Void

    var body: some View {
        MenuView()
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { geo in
                Color.clear.preference(key: SizeKey.self, value: geo.size)
            })
            .onPreferenceChange(SizeKey.self) { onSize(NSSize(width: $0.width, height: $0.height)) }
    }

    private struct SizeKey: PreferenceKey {
        static var defaultValue: CGSize = .zero
        static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
    }
}

// MARK: - Icon drawing

enum StatusIcon {
    /// Every state's symbol drawn centred on the same fixed canvas, so the status item
    /// never changes size (the SF Symbols for each state have different widths).
    private static var cache: [String: NSImage] = [:]
    private static let canvas = NSSize(width: 20, height: 16)

    static func image(for name: String) -> NSImage {
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

    /// Icon followed by the call duration (m:ss / h:mm:ss) in monospaced digits, as one
    /// template image so its width stays steady as the seconds tick.
    static func image(for name: String, time: String) -> NSImage {
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
        result.isTemplate = true
        return result
    }
}
