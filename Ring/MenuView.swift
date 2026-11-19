import SwiftUI
import AppKit

/// Contents of the menu bar popover: main, account and settings pages.
struct MenuView: View {
    enum Page { case main, account, settings, network }

    @EnvironmentObject private var sip: SIPManager
    @State private var page = Page.main
    @State private var window: NSWindow?
    /// Bumped each time the popover opens, so the home page can focus the number field.
    @State private var openCount = 0

    var body: some View {
        Group {
            if page == .account || !sip.settings.isComplete {
                AccountView(onDone: { page = .main })
            } else if page == .settings {
                SettingsView(onDone: { page = .main })
            } else if page == .network {
                NetworkView(onDone: { page = .main })
            } else {
                MainPage(show: { page = $0 }, openCount: openCount, target: $sip.dialTarget)
            }
        }
        .padding(14)
        .frame(width: 280)
        .background(WindowReader(window: $window))
        // When the popover actually closes (its window leaves the screen), go back to the home
        // page for next time. Losing focus, e.g. to a system prompt, doesn't count. While no
        // account is configured the account form is shown regardless, so first-run setup is kept.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
            guard let window, note.object as? NSWindow === window else { return }
            let visible = window.occlusionState.contains(.visible)
            sip.popoverVisibilityChanged(visible) // answers a ringing call if opened via the green icon
            if visible {
                openCount += 1
            } else {
                page = .main
            }
        }
    }
}

/// Exposes the NSWindow hosting a SwiftUI view.
private struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { window = view.window }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if nsView.window !== window {
            DispatchQueue.main.async { window = nsView.window }
        }
    }
}

// MARK: - Main page

private struct MainPage: View {
    @EnvironmentObject private var sip: SIPManager
    let show: (MenuView.Page) -> Void
    let openCount: Int
    @Binding var target: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StatusHeader()

            Divider()
            CallSection(openCount: openCount, target: $target)
            // Errors go under the number field, so the field doesn't jump down when one appears.
            if let err = sip.lastError {
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
            Divider()

            HStack {
                Button("Account…") { show(.account) }
                Button("Audio…") { show(.settings) }
                Button("Network…") { show(.network) }
                if SIPManager.loggingEnabled {
                    Button("Logs") { NSWorkspace.shared.open(SIPManager.logDirectory) }
                        .help("Open the liblinphone log folder")
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .foregroundStyle(.primary) // normal text colour instead of the lighter accent
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderless)
        }
    }
}

private struct StatusHeader: View {
    @EnvironmentObject private var sip: SIPManager

    private var dotColor: Color {
        // Yellow only while re-checking after wake; otherwise straight red <-> green.
        if sip.reconnectingAfterWake { return .yellow }
        if !sip.networkReachable && sip.wantsConnection { return .red }
        switch sip.registration {
        case .connected: return .green
        case .connecting: return .red
        case .disconnected: return .gray
        case .failed: return .red
        }
    }

    var body: some View {
        // Switch is centred against both lines; the address starts at the left edge
        // (not indented under the dot) so long addresses get the full width.
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .center, spacing: 6) {
                    Circle().fill(dotColor).frame(width: 8, height: 8)
                    Text(sip.statusText).font(.headline).lineLimit(2)
                }
                Text(sip.settings.normalizedAddress).font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { sip.wantsConnection }, set: { sip.setConnected($0) }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden()
                .help(sip.wantsConnection ? "Disconnect" : "Connect")
        }
    }
}

private struct CallSection: View {
    @EnvironmentObject private var sip: SIPManager
    let openCount: Int
    @Binding var target: String
    @State private var showKeypad = false
    /// Bumped to ask the number field to take keyboard focus.
    @State private var focusRequest = 0

    var body: some View {
        switch sip.callPhase {
        case .idle:
            HStack {
                DialField(text: $target, placeholder: "Number or SIP address",
                          focusRequest: focusRequest, onSubmit: call,
                          format: { PhoneFormat.partial($0) })
                    .overlay(alignment: .trailing) {
                        if !target.isEmpty {
                            Button {
                                target = ""
                                focusRequest += 1 // keep typing straight away
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Clear")
                            .padding(.trailing, Self.clearButtonTrailing)
                        }
                    }
                // Regular-size button (same corner shape as Hang up), padded out to the field's height.
                Button(action: call) {
                    Image(systemName: "phone.fill").frame(width: 22, height: 19)
                }
                .buttonStyle(.borderedProminent).tint(.callGreen)
                .offset(y: -0.5) // the extra 1 pt of height goes on top only; bottom edge stays put
                .disabled(target.isEmpty || sip.registration != .connected)
            }
            .onAppear {
                showKeypad = false
                focusRequest += 1
            }
            .onChange(of: openCount) { _ in focusRequest += 1 }

        case .incoming(let remote):
            VStack(alignment: .leading, spacing: 10) {
                callHeader(remote) { Text("Incoming…").foregroundStyle(.secondary) }
                HStack {
                    Button(role: .destructive) { sip.hangUp() } label: {
                        Label("Decline", systemImage: "phone.down.fill")
                    }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button { sip.answer() } label: {
                        Label("Answer", systemImage: "phone.fill")
                    }
                        .buttonStyle(.borderedProminent).tint(.callGreen)
                        .keyboardShortcut(.defaultAction)
                }
            }

        case .outgoing(let remote):
            VStack(alignment: .leading, spacing: 10) {
                callHeader(remote) { Text("Calling…").foregroundStyle(.secondary) }
                HangUpButton()
            }

        case .active(let remote, let since):
            VStack(alignment: .leading, spacing: 10) {
                callHeader(remote) {
                    TimelineView(.periodic(from: since, by: 1)) { ctx in
                        Text(formatCallDuration(Int(ctx.date.timeIntervalSince(since))))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                if !sip.networkReachable {
                    Label("Network lost — trying to reconnect…", systemImage: "wifi.exclamationmark")
                        .font(.caption).foregroundStyle(Color.mutedText)
                }
                HangUpButton()
                HStack {
                    // Equal halves, so the layout doesn't shift between "Mute" and "Unmute".
                    Button { sip.toggleMute() } label: {
                        Label(sip.isMuted ? "Unmute" : "Mute",
                              systemImage: sip.isMuted ? "mic.slash.fill" : "mic.fill")
                            .frame(maxWidth: .infinity)
                            // Only the text/icon changes colour when muted; the background stays.
                            .foregroundStyle(sip.isMuted ? Color.mutedText : Color.primary)
                    }
                    Button { showKeypad.toggle() } label: {
                        Label("Keypad", systemImage: "circle.grid.3x3.fill")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                if showKeypad { Keypad() }
            }
        }
    }

    /// Same top row in every call state: the number on the left, the state ("Incoming call",
    /// "Calling…") or the timer on the right. Keeps the number and the buttons below in place.
    private func callHeader<Trailing: View>(_ remote: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(remote).font(.title3).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            trailing()
        }
    }

    /// Gap between the clear (x) button and the field's right edge. macOS 15's field has a
    /// thinner bezel, so the button needs a bit more room there to not look flush.
    private static var clearButtonTrailing: CGFloat {
        if #available(macOS 26.0, *) { return 6 }
        return 8
    }

    private func call() {
        sip.dial(target)
    }

}

private struct HangUpButton: View {
    @EnvironmentObject private var sip: SIPManager

    var body: some View {
        Button(role: .destructive) { sip.hangUp() } label: {
            Label("Hang up", systemImage: "phone.down.fill").frame(maxWidth: .infinity, minHeight: 19)
        }
        .buttonStyle(.borderedProminent).tint(.callRed)
    }
}

/// DTMF keypad. Buttons send digits; typing 0-9 * # also works while the popover is focused.
private struct Keypad: View {
    @EnvironmentObject private var sip: SIPManager
    private let rows: [[Character]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["*", "0", "#"]]

    var body: some View {
        Grid(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(rows, id: \.self) { row in
                GridRow {
                    ForEach(row, id: \.self) { key in
                        Button { sip.sendDTMF(key) } label: {
                            Text(String(key)).font(.title3.monospacedDigit()).frame(maxWidth: .infinity, minHeight: 28)
                        }
                        .buttonStyle(.bordered)
                        .keyboardShortcut(KeyEquivalent(key), modifiers: [])
                    }
                }
            }
        }
    }
}

// MARK: - Account page

private struct AccountView: View {
    @EnvironmentObject private var sip: SIPManager
    @State private var draft = AccountSettings()
    @State private var showAdvanced = false
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Account Settings").font(.headline)
            Divider()

            field("SIP address", "sip:alice@example.com", $draft.sipAddress)
            VStack(alignment: .leading, spacing: 3) {
                Text("Password").font(.caption).foregroundStyle(.secondary)
                SecureField("", text: $draft.password).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Country").font(.caption).foregroundStyle(.secondary)
                Picker("Country", selection: $draft.phoneRegion) {
                    Text("Automatic (\(PhoneFormat.countryName(PhoneFormat.automaticRegion)))").tag("")
                    Divider()
                    ForEach(PhoneFormat.countries, id: \.code) { country in
                        Text(country.name).tag(country.code)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            DisclosureGroup(isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 10) {
                    field("Username (optional)", "Defaults to the user part of the address", $draft.username)
                    field("Server (optional)", "host[:port], defaults to the address's domain", $draft.server)
                    Toggle("Use TLS Signalling", isOn: $draft.useTLS)
                    Toggle("System-drawn menu bar icon", isOn: $draft.systemMenuBarIcon)
                }
                .padding(.top, 6)
            } label: {
                // Make the text clickable too, not just the arrow.
                Text("Advanced Options...")
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation { showAdvanced.toggle() } }
            }

            Divider()
            HStack {
                if sip.settings.isComplete {
                    Button("Cancel", action: onDone).keyboardShortcut(.cancelAction)
                } else {
                    Button("Quit") { NSApp.terminate(nil) }
                }
                Spacer()
                Button("Save") {
                    sip.update(settings: draft)
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!draft.isComplete)
            }
        }
        .onAppear {
            draft = sip.settings
            // Start expanded if any advanced option differs from its default, so it isn't hidden.
            showAdvanced = !draft.username.isEmpty || !draft.server.isEmpty || !draft.useTLS
        }
    }

    private func field(_ label: String, _ prompt: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(prompt, text: text).textFieldStyle(.roundedBorder)
        }
    }
}

// MARK: - Settings page

private struct SettingsView: View {
    @EnvironmentObject private var sip: SIPManager
    @State private var draft = AudioSettings()
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Audio Settings").font(.headline)
            Divider()

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Volume gain")
                    Spacer()
                    Text(draft.speakerBoostDb == 0 ? "Off" : "+\(draft.speakerBoostDb) dB")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { Double(draft.speakerBoostDb) },
                                      set: {
                                          draft.speakerBoostDb = Int($0.rounded())
                                          sip.previewSpeakerBoost(draft.speakerBoostDb) // live, incl. during a call
                                      }),
                       in: Double(AudioSettings.speakerBoostRange.lowerBound)...Double(AudioSettings.speakerBoostRange.upperBound),
                       step: 1)
            }

            Toggle("Echo cancellation (experimental)", isOn: $draft.echoCancellation)

            Toggle("Adaptive buffer (experimental)", isOn: $draft.adaptiveJitterBuffer)
            if !draft.adaptiveJitterBuffer {
                Stepper(value: $draft.jitterBufferMs, in: AudioSettings.jitterBufferRange, step: 10) {
                    HStack(spacing: 4) {
                        Text("Fixed buffer size")
                        Spacer()
                        TextField("", value: $draft.jitterBufferMs, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 52).multilineTextAlignment(.trailing)
                        Text("ms")
                    }
                }
            }

            Divider()

            Text("Codec Support").font(.subheadline.weight(.semibold))
            ForEach(Codec.allCases) { codec in
                Toggle(codec.label, isOn: Binding(
                    get: { draft.enabledCodecs.contains(codec) },
                    set: { on in
                        if on { draft.enabledCodecs.insert(codec) } else { draft.enabledCodecs.remove(codec) }
                    }))
            }
            Text(draft.enabledCodecs.isEmpty ? "Enable at least one codec."
                                             : "Changes apply from the next call.")
                .font(.caption).foregroundStyle(draft.enabledCodecs.isEmpty ? Color.orange : Color.secondary)

            Divider()
            HStack {
                Button("Cancel", action: onDone).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    sip.update(audio: draft)
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(draft.enabledCodecs.isEmpty)
            }
        }
        .onAppear { draft = sip.audio }
        // Leaving without Save (Cancel, or the popover closing) drops the previewed boost;
        // after Save this just re-applies the new saved value.
        .onDisappear { sip.restoreSpeakerBoost() }
        .onChange(of: draft.jitterBufferMs) { ms in
            let r = AudioSettings.jitterBufferRange
            if !r.contains(ms) { draft.jitterBufferMs = min(max(ms, r.lowerBound), r.upperBound) }
        }
    }
}

// MARK: - Network page

private struct NetworkView: View {
    @EnvironmentObject private var sip: SIPManager
    @State private var draft = NetworkSettings()
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Network Settings").font(.headline)
            Divider()

            Toggle("Enable IPv6", isOn: $draft.ipv6)

            Divider()

            VStack(alignment: .leading, spacing: 3) {
                Text("STUN/TURN server").font(.caption).foregroundStyle(.secondary)
                TextField("host[:port], e.g. stun.example.com", text: $draft.stunServer)
                    .textFieldStyle(.roundedBorder)
            }
            Toggle("Enable ICE", isOn: $draft.ice)
            Toggle("Enable TURN", isOn: $draft.turn)
                .disabled(!draft.hasServer)
            if draft.turn && draft.hasServer {
                VStack(alignment: .leading, spacing: 3) {
                    Text("TURN username").font(.caption).foregroundStyle(.secondary)
                    TextField("", text: $draft.turnUsername).textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("TURN password").font(.caption).foregroundStyle(.secondary)
                    SecureField("", text: $draft.turnPassword).textFieldStyle(.roundedBorder)
                }
            }

            Divider()
            HStack {
                Button("Cancel", action: onDone).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    sip.update(network: draft)
                    onDone()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .onAppear { draft = sip.network }
    }
}

// MARK: - Number field

/// The number field, as a native NSTextField so its focus ring can be switched off entirely
/// (SwiftUI's focusEffectDisabled doesn't stop the animated ring on this field).
private struct DialField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    /// Changing this value focuses the field.
    let focusRequest: Int
    let onSubmit: () -> Void
    /// As-you-type formatting (brackets, spaces, hyphens for phone numbers).
    let format: (String) -> String

    func makeNSView(context: Context) -> NSTextField {
        let field = PaddedTextField()
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 15)
        field.controlSize = .large
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
            context.coordinator.syncPrevious(text)
        }
        if context.coordinator.handledFocusRequest != focusRequest {
            context.coordinator.handledFocusRequest = focusRequest
            // Next tick, once the popover window is key.
            DispatchQueue.main.async {
                guard let window = field.window else { return }
                window.makeFirstResponder(field)
                field.currentEditor()?.selectedRange = NSRange(location: field.stringValue.count, length: 0)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: DialField
        var handledFocusRequest = -1
        init(_ parent: DialField) { self.parent = parent }
        func syncPrevious(_ text: String) { previous = text }

        private var previous = ""

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            var raw = field.stringValue
            // Backspacing over a ")" or "-" only removes formatting that would be re-added
            // straight away; remove the digit before it instead so deleting still works.
            let digits = { (s: String) in s.filter(\.isNumber) }
            if raw.count < previous.count, digits(raw) == digits(previous), let i = raw.lastIndex(where: \.isNumber) {
                raw.remove(at: i)
            }
            let formatted = parent.format(raw)
            if formatted != field.stringValue { field.stringValue = formatted }
            previous = formatted
            parent.text = formatted
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            // Escape: the field editor would swallow it. Step out of the field and hand the
            // same key press to the popover window, which closes on Escape as before.
            if selector == #selector(NSResponder.cancelOperation(_:)),
               let window = control.window, let event = NSApp.currentEvent, event.type == .keyDown {
                window.makeFirstResponder(nil)
                window.sendEvent(event)
                return true
            }
            return false
        }
    }
}

/// NSTextField whose text sits a little further in from the rounded border. Before macOS 26 the
/// text nearly touches the border; macOS 26's field already has enough room, so no extra inset.
private final class PaddedTextField: NSTextField {
    override class var cellClass: AnyClass? {
        get { PaddedTextFieldCell.self }
        set {}
    }
}

private final class PaddedTextFieldCell: NSTextFieldCell {
    /// Extra room between the border and the text (macOS 26's field already has enough).
    private var leftInset: CGFloat {
        if #available(macOS 26.0, *) { return 0 }
        return 1
    }
    /// Same on the right, plus room for the clear (x) button so text never runs under it.
    private var rightInset: CGFloat { leftInset + 10 }

    private func padded(_ rect: NSRect) -> NSRect {
        var r = rect
        r.origin.x += leftInset
        r.size.width = max(0, r.size.width - leftInset - rightInset)
        return r
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        padded(super.drawingRect(forBounds: rect))
    }

    // Keep the caret / editing area in the same place as the drawn text.
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                       delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: padded(rect), in: controlView, editor: textObj,
                   delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                         delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: padded(rect), in: controlView, editor: textObj,
                     delegate: delegate, start: selStart, length: selLength)
    }
}
