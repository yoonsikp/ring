import SwiftUI
import AppKit

/// Contents of the menu bar popover: main, account and settings pages.
struct MenuView: View {
    enum Page { case main, account, settings }

    @EnvironmentObject private var sip: SIPManager
    @State private var page = Page.main

    var body: some View {
        Group {
            if page == .account || !sip.settings.isComplete {
                AccountView(onDone: { page = .main })
            } else if page == .settings {
                SettingsView(onDone: { page = .main })
            } else {
                MainPage(show: { page = $0 })
            }
        }
        .padding(14)
        .frame(width: 280)
    }
}

// MARK: - Main page

private struct MainPage: View {
    @EnvironmentObject private var sip: SIPManager
    let show: (MenuView.Page) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StatusHeader()

            if let err = sip.lastError {
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(3)
            }

            Divider()
            CallSection()
            Divider()

            HStack {
                Button("Account…") { show(.account) }
                Button("Settings…") { show(.settings) }
                if SIPManager.loggingEnabled {
                    Button("Logs") { NSWorkspace.shared.open(SIPManager.logDirectory) }
                        .help("Open the liblinphone log folder")
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
    }
}

private struct StatusHeader: View {
    @EnvironmentObject private var sip: SIPManager

    private var dotColor: Color {
        switch sip.registration {
        case .connected: return .green
        case .connecting: return .yellow
        case .disconnected: return .gray
        case .failed: return .red
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Circle().fill(dotColor).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(sip.statusText).font(.headline).lineLimit(2)
                Text(sip.settings.normalizedAddress).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { sip.wantsConnection }, set: { sip.setConnected($0) }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden()
                .help(sip.wantsConnection ? "Disconnect" : "Connect")
        }
    }
}

private struct CallSection: View {
    @EnvironmentObject private var sip: SIPManager
    @State private var target = ""
    @State private var showKeypad = false

    var body: some View {
        switch sip.callPhase {
        case .idle:
            HStack {
                TextField("Number or SIP address", text: $target)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(call)
                Button(action: call) { Image(systemName: "phone.fill") }
                    .buttonStyle(.borderedProminent).tint(.green)
                    .disabled(target.isEmpty || sip.registration != .connected)
            }
            .onAppear { showKeypad = false }

        case .incoming(let remote):
            VStack(alignment: .leading, spacing: 8) {
                Label("Incoming call", systemImage: "phone.arrow.down.left").font(.subheadline)
                Text(remote).font(.title3).lineLimit(1).truncationMode(.middle)
                HStack {
                    Button("Decline", role: .destructive) { sip.hangUp() }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("Answer") { sip.answer() }
                        .buttonStyle(.borderedProminent).tint(.green)
                        .keyboardShortcut(.defaultAction)
                }
            }

        case .outgoing(let remote):
            VStack(alignment: .leading, spacing: 8) {
                Label("Calling…", systemImage: "phone.arrow.up.right").font(.subheadline)
                Text(remote).font(.title3).lineLimit(1).truncationMode(.middle)
                HangUpButton()
            }

        case .active(let remote, let since):
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(remote).font(.title3).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    TimelineView(.periodic(from: since, by: 1)) { ctx in
                        Text(Self.format(ctx.date.timeIntervalSince(since)))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button { sip.toggleMute() } label: {
                        Label(sip.isMuted ? "Unmute" : "Mute",
                              systemImage: sip.isMuted ? "mic.slash.fill" : "mic.fill")
                    }
                    .tint(sip.isMuted ? .orange : nil)
                    Button { showKeypad.toggle() } label: {
                        Label("Keypad", systemImage: "circle.grid.3x3.fill")
                    }
                    Spacer()
                }
                .buttonStyle(.bordered)
                if showKeypad { Keypad() }
                HangUpButton()
            }
        }
    }

    private func call() {
        sip.dial(target)
    }

    private static func format(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct HangUpButton: View {
    @EnvironmentObject private var sip: SIPManager

    var body: some View {
        Button(role: .destructive) { sip.hangUp() } label: {
            Label("Hang up", systemImage: "phone.down.fill").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent).tint(.red)
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
            Text("SIP Account").font(.headline)

            field("SIP address", "sip:alice@example.com", $draft.sipAddress)
            VStack(alignment: .leading, spacing: 3) {
                Text("Password").font(.caption).foregroundStyle(.secondary)
                SecureField("", text: $draft.password).textFieldStyle(.roundedBorder)
            }

            DisclosureGroup(isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 10) {
                    field("Username (optional)", "Defaults to the user part of the address", $draft.username)
                    field("Server (optional)", "host[:port], defaults to the address's domain", $draft.server)
                    Toggle("Use TLS Signalling", isOn: $draft.useTLS)
                }
                .padding(.top, 6)
            } label: {
                // Make the text clickable too, not just the arrow.
                Text("Advanced Options...")
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation { showAdvanced.toggle() } }
            }

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
            Text("Settings").font(.headline)

            Toggle("Echo cancellation", isOn: $draft.echoCancellation)
            Text("Needed on speakers. Turn off with headphones: it can make the other side choppy or delayed.")
                .font(.caption).foregroundStyle(.secondary)

            Divider()

            Text("Codecs").font(.subheadline.weight(.semibold))
            ForEach(Codec.allCases) { codec in
                Toggle(codec.label, isOn: Binding(
                    get: { draft.enabledCodecs.contains(codec) },
                    set: { on in
                        if on { draft.enabledCodecs.insert(codec) } else { draft.enabledCodecs.remove(codec) }
                    }))
            }
            Text(draft.enabledCodecs.isEmpty ? "Enable at least one codec."
                                             : "All other codecs are disabled. Changes apply from the next call.")
                .font(.caption).foregroundStyle(draft.enabledCodecs.isEmpty ? Color.orange : Color.secondary)

            Divider()

            Text("Jitter buffer").font(.subheadline.weight(.semibold))
            Toggle("Adaptive", isOn: $draft.adaptiveJitterBuffer)
            if !draft.adaptiveJitterBuffer {
                Stepper(value: $draft.jitterBufferMs, in: AudioSettings.jitterBufferRange, step: 10) {
                    HStack(spacing: 4) {
                        Text("Fixed size")
                        Spacer()
                        TextField("", value: $draft.jitterBufferMs, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 52).multilineTextAlignment(.trailing)
                        Text("ms")
                    }
                }
            }
            Text(draft.adaptiveJitterBuffer
                 ? "Grows and shrinks with network conditions."
                 : "Constant delay. Lower = less lag; too low causes dropouts on a jittery network.")
                .font(.caption).foregroundStyle(.secondary)

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
        .onChange(of: draft.jitterBufferMs) { ms in
            let r = AudioSettings.jitterBufferRange
            if !r.contains(ms) { draft.jitterBufferMs = min(max(ms, r.lowerBound), r.upperBound) }
        }
    }
}
