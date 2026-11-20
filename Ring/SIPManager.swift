import Foundation
import AppKit
import AVFoundation
import linphonesw

/// Wraps a single liblinphone Core: one account, at most one call.
@MainActor
final class SIPManager: ObservableObject {
    enum Registration: Equatable {
        case disconnected, connecting, connected, failed(String)
    }

    enum CallPhase: Equatable {
        case idle
        case incoming(remote: String)
        case outgoing(remote: String)
        case active(remote: String, since: Date)
    }

    @Published private(set) var registration: Registration = .disconnected { didSet { updatePowerMode() } }
    @Published private(set) var callPhase: CallPhase = .idle { didSet { updatePowerMode() } }
    @Published private(set) var isMuted = false
    @Published private(set) var lastError: String?
    @Published private(set) var settings = AccountSettings.load()
    @Published private(set) var audio = AudioSettings.load()
    @Published private(set) var network = NetworkSettings.load()
    /// The number field's contents. Lives here so incoming calls can fill in the caller.
    @Published var dialTarget = ""
    /// System notification with Answer / Decline for incoming calls.
    private let notifier = CallNotifier()
    /// Whether the menu bar popover is on screen (reported by MenuView).
    @Published private(set) var popoverOpen = false
    /// Call duration for the menu bar (ticks separately from the rest of the UI).
    let clock = CallClock()
    /// User intent: whether we *want* to be registered (the menu's Connect/Disconnect toggle).
    @Published private(set) var wantsConnection = true
    /// liblinphone's own network monitoring (it closes connections when the network goes and
    /// reconnects / re-registers by itself when it comes back).
    @Published private(set) var networkReachable = true
    /// True from waking from sleep until we're registered again (or 30 s pass). The only time
    /// the status dot is yellow.
    @Published private(set) var reconnectingAfterWake = false
    private var wakeObserver: NSObjectProtocol?
    private var wakeGeneration = 0
    /// Account changes (disconnect switch, new settings) wait until the current call has ended.
    private var accountApplyPending = false

    private var core: Core!
    private var delegate: CoreDelegateStub!
    private var iterateTimer: Timer?
    /// nil until first set; true while a call is ringing/active or we're registering.
    private var isBusy: Bool?
    private var ticksSinceSync = 0
    /// The single account we created; events from previously removed accounts are ignored.
    private var activeAccount: Account?
    /// Keeps App Nap from throttling us, so we keep the SIP connection alive and hear incoming calls.
    /// Latency-critical only while busy; see `updatePowerMode()`.
    private var activity: NSObjectProtocol?

    /// Detailed logging is only on when launched with `--logging` (logs contain SRTP keys).
    static let loggingEnabled = CommandLine.arguments.contains("--logging")

    /// liblinphone logs go here (~/Library/Logs/Ring).
    static let logDirectory: URL = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Ring", isDirectory: true)

    init() {
        Self.applyLogging(Self.loggingEnabled) // before the core exists, so startup is logged too

        // Keep liblinphone's databases in our own folder, not the shared ~/Library/Application Support/linphone.
        let dataDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ring", isDirectory: true)
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        Factory.Instance.dataDir = dataDir.path
        Factory.Instance.configDir = dataDir.path

        do {
            // No config path: nothing (in particular no password) is persisted by liblinphone.
            core = try Factory.Instance.createCore(configPath: nil, factoryConfigPath: nil, systemContext: nil)
        } catch {
            fatalError("Could not create liblinphone core: \(error)")
        }

        // Random local ports (like the Linphone apps) so we never fight another SIP app for 5060.
        if let transports = try? Factory.Instance.createTransports() {
            transports.udpPort = -1
            transports.tcpPort = -1
            transports.tlsPort = -1
            try? core.setTransports(newValue: transports)
        }

        // Custom ring tone (Ring/Sounds/ringtone.mkv: Opus, mono 48 kHz, already at half volume;
        // the same container/codec as the SDK's own ring tones).
        if let ringtone = Bundle.main.path(forResource: "ringtone", ofType: "mkv") {
            core.ring = ringtone
        }

        core.maxCalls = 1                      // one call at a time; extra INVITEs get 486 Busy
        core.videoCaptureEnabled = false       // audio only
        core.videoDisplayEnabled = false
        if let policy = try? Factory.Instance.createVideoActivationPolicy() {
            policy.automaticallyInitiate = false
            policy.automaticallyAccept = false
            core.videoActivationPolicy = policy
        }
        // Features Ring doesn't use: chat, end-to-end message encryption, friend lists.
        core.disableChat(denyReason: .NotImplemented)
        core.limeX3DhEnabled = false
        core.friendListSubscriptionEnabled = false
        // No bitrate adaptation (pointless with fixed-rate codecs) and no RTCP-XR call reports.
        core.adaptiveRateControlEnabled = false
        core.config?.setBool(section: "rtp", key: "rtcp_xr_enabled", value: false)

        try? core.setMediaencryption(newValue: .SRTP)
        core.mediaEncryptionMandatory = true   // refuse calls that can't do SRTP

        delegate = CoreDelegateStub(
            onCallStateChanged: { [weak self] _, call, state, message in
                MainActor.assumeIsolated { self?.handleCall(call, state: state, message: message) }
            },
            onNetworkReachable: { [weak self] _, reachable in
                MainActor.assumeIsolated { self?.networkReachable = reachable }
            },
            onAccountRegistrationStateChanged: { [weak self] _, account, state, message in
                MainActor.assumeIsolated { self?.handleRegistration(account, state: state, message: message) }
            }
        )
        core.addDelegate(delegate: delegate)

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWake() }
        }

        // We drive the core ourselves; the rate depends on whether a call is going on.
        core.autoIterateEnabled = false

        do { try core.start() } catch { lastError = "Core start failed: \(error)" }
        PhoneFormat.regionSetting = settings.phoneRegion

        // Ask for the microphone up front (notifications are requested by CallNotifier at
        // launch too), so neither prompt interrupts the first call.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }

        notifier.onAnswer = { [weak self] in
            guard let self, case .incoming = self.callPhase else { return }
            self.answer()
        }
        notifier.onDecline = { [weak self] in
            guard let self, case .incoming = self.callPhase else { return }
            self.hangUp()
        }

        applyAudio()
        applyNetwork()
        applyAccount()
        updatePowerMode()
    }

    // MARK: - Power

    /// Fast iteration and latency-critical activity only while ringing, in a call or registering.
    /// When idle, iterate 5x/s with timer tolerance so macOS can coalesce wake-ups: an incoming
    /// INVITE is then picked up within ~0.25 s, and keep-alives/re-registration don't need more.
    private func updatePowerMode() {
        guard core != nil else { return } // property observers can fire before the core exists
        let busy = callPhase != .idle || registration == .connecting
        guard busy != isBusy else { return }
        isBusy = busy

        iterateTimer?.invalidate()
        let timer = Timer(timeInterval: busy ? 0.02 : 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.core.iterate()
                // About every 5 s, check the status shown still matches the account's real state.
                self.ticksSinceSync += 1
                if self.ticksSinceSync >= (busy ? 250 : 25) {
                    self.ticksSinceSync = 0
                    self.syncRegistration()
                }
            }
        }
        timer.tolerance = busy ? 0.002 : 0.05
        RunLoop.main.add(timer, forMode: .common) // .common: keeps running while the menu is open
        iterateTimer = timer

        // Still opt out of App Nap when idle (so we don't miss calls), but only ask for
        // latency-critical scheduling while busy.
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = ProcessInfo.processInfo.beginActivity(
            options: busy ? [.userInitiatedAllowingIdleSystemSleep, .latencyCritical]
                          : [.userInitiatedAllowingIdleSystemSleep],
            reason: busy ? "SIP call in progress" : "Listening for incoming SIP calls")
        // Note: no direct core.iterate() here; this often runs inside a core callback.
    }

    func shutdown() {
        // Hang up gracefully: give liblinphone a moment to actually send the BYE before stopping.
        if !core.calls.isEmpty {
            try? core.terminateAllCalls()
            for _ in 0..<25 { // up to ~0.5 s
                core.iterate()
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        core.stop() // also unregisters
        iterateTimer?.invalidate()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }

    // MARK: - Account

    func update(settings new: AccountSettings) {
        new.save()
        PhoneFormat.regionSetting = new.phoneRegion
        // The phone-number country is display-only; it doesn't need a re-registration.
        var old = settings, cmp = new
        old.phoneRegion = ""; cmp.phoneRegion = ""
        let changed = cmp != old
        settings = new
        guard changed else { return } // only re-register if the account actually changed
        if trackedCall != nil {
            accountApplyPending = true // re-register once the current call ends
        } else {
            applyAccount()
        }
    }

    /// Audio preferences never touch the registration; they apply from the next call.
    func update(audio new: AudioSettings) {
        new.save()
        audio = new
        applyAudio()
    }

    private static func applyLogging(_ on: Bool) {
        if on {
            try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            Core.setLogCollectionPath(path: logDirectory.path)
            Core.enableLogCollection(state: .Enabled)
            LoggingService.Instance.logLevel = .Message
        } else {
            Core.enableLogCollection(state: .Disabled)
            LoggingService.Instance.logLevel = .Error
        }
    }

    /// Set the speaker boost immediately (used while dragging the slider), without saving.
    func previewSpeakerBoost(_ db: Int) {
        core.playbackGainDb = Float(db)
    }

    /// Put the speaker boost back to the saved value (e.g. after Cancel).
    func restoreSpeakerBoost() {
        core.playbackGainDb = Float(audio.speakerBoostDb)
    }

    /// NAT traversal and IPv6 apply from the next call / connection.
    func update(network new: NetworkSettings) {
        new.save()
        network = new
        applyNetwork()
    }

    private func applyNetwork() {
        core.ipv6Enabled = network.ipv6
        guard let policy = try? core.createNatPolicy() else { return }
        let server = network.stunServer.trimmingCharacters(in: .whitespaces)
        if !server.isEmpty {
            policy.stunServer = server
            policy.stunEnabled = true
        }
        policy.iceEnabled = network.ice
        policy.turnEnabled = network.turn && !server.isEmpty
        if policy.turnEnabled {
            policy.udpTurnTransportEnabled = true
            policy.stunServerUsername = network.turnUsername
        }
        core.natPolicy = policy
        addTurnAuth()
    }

    /// liblinphone finds TURN credentials as an AuthInfo matching `stunServerUsername`.
    /// Re-added after applyAccount(), which clears all auth info.
    private func addTurnAuth() {
        guard network.turn, network.hasServer, !network.turnUsername.isEmpty,
              let auth = try? Factory.Instance.createAuthInfo(
                  username: network.turnUsername, userid: nil, passwd: network.turnPassword,
                  ha1: nil, realm: nil, domain: nil) else { return }
        core.addAuthInfo(info: auth)
    }

    private func applyAudio() {
        core.echoCancellationEnabled = audio.echoCancellation
        core.playbackGainDb = Float(audio.speakerBoostDb)
        core.audioAdaptiveJittcompEnabled = audio.adaptiveJitterBuffer
        core.audioJittcomp = audio.jitterBufferMs // fixed size, or the starting size when adaptive
        let allowed = Set(audio.enabledCodecs.flatMap(\.mimeTypes))
        for pt in core.audioPayloadTypes {
            let mime = pt.mimeType.uppercased()
            // telephone-event carries DTMF (RFC 2833); it isn't a voice codec, so keep it on.
            let on = mime == "TELEPHONE-EVENT" || allowed.contains(mime)
            _ = pt.enable(enabled: on)
        }
    }

    func setConnected(_ on: Bool) {
        wantsConnection = on
        if !on, trackedCall != nil {
            // Disconnecting during a call: hang up first (BYE/decline), unregister after it ends.
            accountApplyPending = true
            hangUp()
            // Fallback in case the call never reports ending.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.applyPendingAccount()
            }
            return
        }
        accountApplyPending = false
        reconnectingAfterWake = false
        applyAccount()
    }

    /// After sleep the TLS connection to the server is almost certainly dead, but nothing may
    /// notice until the next keep-alive fails. Drop the connections and re-register right away.
    private func handleWake() {
        guard wantsConnection, settings.isComplete, activeAccount != nil else { return }
        reconnectingAfterWake = true
        wakeGeneration += 1
        let generation = wakeGeneration
        if trackedCall == nil {
            core.networkReachable = false // closes all connections
            core.networkReachable = true  // reconnects and re-registers
        } else {
            core.refreshRegisters()       // don't tear down a call in progress
        }
        // Give Wi-Fi time to rejoin; stop showing "Reconnecting…" after 30 s regardless.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.wakeGeneration == generation else { return }
            self.reconnectingAfterWake = false
        }
    }

    private func applyPendingAccount() {
        guard accountApplyPending else { return }
        accountApplyPending = false
        applyAccount()
    }

    /// Tear down whatever account exists and (re)create the single configured one.
    private func applyAccount() {
        lastError = nil
        activeAccount = nil
        core.clearAccounts()
        core.clearAllAuthInfo()
        registration = .disconnected

        guard settings.isComplete, wantsConnection else { return }

        do {
            let factory = Factory.Instance
            let identity = try factory.createAddress(addr: settings.normalizedAddress)
            guard let domain = identity.domain, !domain.isEmpty else {
                registration = .failed("SIP address has no domain")
                return
            }
            let authUser = settings.username.isEmpty ? (identity.username ?? "") : settings.username

            let host = settings.server.trimmingCharacters(in: .whitespaces)
            let serverAddr = try factory.createAddress(addr: "sip:" + (host.isEmpty ? domain : host))
            try serverAddr.setTransport(newValue: settings.useTLS ? .Tls : .Udp)

            let params = try core.createAccountParams()
            try params.setIdentityaddress(newValue: identity)
            try params.setServeraddress(newValue: serverAddr)
            params.registerEnabled = true

            let auth = try factory.createAuthInfo(username: authUser, userid: nil, passwd: settings.password,
                                                  ha1: nil, realm: nil, domain: domain)
            core.addAuthInfo(info: auth)
            addTurnAuth()

            let account = try core.createAccount(params: params)
            try core.addAccount(account: account)
            core.defaultAccount = account
            activeAccount = account
            registration = .connecting
        } catch {
            registration = .failed("Invalid account settings")
            lastError = "\(error)"
        }
    }

    /// Turn liblinphone's registration error into something readable.
    private static func registrationFailure(_ info: ErrorInfo?, message: String) -> String {
        let code = info?.protocolCode ?? 0
        switch (code, info?.reason ?? .None) {
        case (401, _), (403, _), (407, _), (_, .Unauthorized), (_, .Forbidden):
            return "Wrong username or password"
        case (408, _), (503, _), (_, .IOError), (_, .NoResponse), (_, .ServerTimeout):
            return "Can't reach the server"
        case (404, _), (_, .NotFound):
            return "Account not found on the server"
        default:
            if let phrase = info?.phrase, !phrase.isEmpty { return phrase }
            return message.isEmpty ? "Registration failed" : message
        }
    }

    private func handleRegistration(_ account: Account, state: RegistrationState, message: String) {
        guard let active = activeAccount, account === active else { return }
        switch state {
        case .Ok:
            registration = .connected
            reconnectingAfterWake = false
        case .Progress: registration = .connecting
        case .Failed: registration = .failed(Self.registrationFailure(account.errorInfo, message: message))
        case .Cleared, .None: registration = .disconnected
        default: break // e.g. Refreshing: keep current state
        }
    }

    /// Make the shown status match the account's actual registration state, in case a state
    /// change callback was missed (e.g. around sleep/wake): "Disconnected" must really mean it.
    private func syncRegistration() {
        guard let account = activeAccount else {
            if registration != .disconnected, !accountApplyPending { registration = .disconnected }
            return
        }
        let actual: Registration
        switch account.state {
        case .Ok, .Refreshing: actual = .connected
        case .Progress: actual = .connecting
        case .Failed:
            if case .failed = registration { return } // keep the existing message
            actual = .failed(Self.registrationFailure(account.errorInfo, message: ""))
        case .Cleared, .None: actual = .disconnected
        default: return
        }
        if actual != registration {
            registration = actual
            if actual == .connected { reconnectingAfterWake = false }
        }
    }

    // MARK: - Calls

    /// The one call the UI is showing. Events from any other call (an old call's late
    /// Released, or a second INVITE auto-rejected as busy) must not change the UI.
    private var trackedCall: Call?
    private var currentCall: Call? { trackedCall }

    func dial(_ input: String) {
        // Strip display formatting: "(431) 334-7050" → "4313347050"; SIP addresses unchanged.
        let target = PhoneFormat.dialString(input)
        guard !target.isEmpty, callPhase == .idle else { return }
        lastError = nil // a new attempt clears the previous call's error
        guard registration == .connected else { lastError = "Not connected"; return }

        requestMicAccess { [weak self] granted in
            guard let self else { return }
            guard granted else { self.lastError = "Microphone access denied (System Settings → Privacy)"; return }
            guard let addr = self.core.interpretUrl(url: target, applyInternationalPrefix: false) else {
                self.lastError = "Invalid address: \(target)"; return
            }
            do {
                let params = try self.core.createCallParams(call: nil)
                params.mediaEncryption = .SRTP
                params.videoEnabled = false
                if let call = self.core.inviteAddressWithParams(addr: addr, params: params) {
                    // Usually already set by the OutgoingInit callback; don't adopt a call that already died.
                    if self.trackedCall == nil, ![.Error, .End, .Released].contains(call.state) {
                        self.trackedCall = call
                    }
                } else {
                    self.lastError = "Call could not be started"
                }
            } catch {
                self.lastError = "\(error)"
            }
        }
    }

    func answer() {
        guard let call = currentCall else { return }
        requestMicAccess { [weak self] granted in
            guard granted else {
                self?.lastError = "Microphone access denied"
                try? call.decline(reason: .Declined)
                return
            }
            do { try call.accept() } catch { self?.lastError = "\(error)" }
        }
    }

    func hangUp() {
        guard let call = currentCall else { return }
        if case .incoming = callPhase {
            try? call.decline(reason: .Declined)
        } else {
            try? call.terminate()
        }
    }

    // MARK: - Call links

    static let callLinkSchemes = ["tel", "sip", "sips", "callto"]
    /// When Ring started; a call link arriving within a few seconds of this launched Ring.
    private let launchedAt = Date()

    /// A clicked call link fills the number field and opens the popover; the user presses Call.
    /// (Never dials by itself, so a stray click can't place a call.)
    func handleCallLink(_ url: URL) {
        guard let target = Self.callLinkTarget(url), !target.isEmpty else { return }
        dialTarget = target
        lastError = nil
        guard !popoverOpen, !MenuBarPopover.isShown else { return }
        if Date().timeIntervalSince(launchedAt) < 5 {
            // The link launched Ring: it's still starting up, and the browser takes focus back
            // meanwhile, so open the popover patiently (delay, then reopen once if needed).
            NSApp.activate(ignoringOtherApps: true)
            openPopoverForLink()
        } else {
            // Ring was already running: just open the popover.
            MenuBarPopover.statusItemButton()?.performClick(nil)
        }
    }

    /// Opens the popover for a call link that launched Ring. After handing over the
    /// link, the browser usually takes focus back, and macOS closes a menu bar popover when
    /// another app becomes active. So wait a moment before clicking the status item, and if the
    /// popover didn't stay open after that click, reopen it once. As soon as it's seen open, stop:
    /// closing it yourself afterwards is left alone.
    private func openPopoverForLink(waits: Int = 0, clicks: Int = 0, delay: TimeInterval = 1.0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            if MenuBarPopover.isShown { return } // it's open: done
            guard clicks < 2 else { return }      // the first open plus one reopen
            guard let button = MenuBarPopover.statusItemButton() else {
                // The link may have launched Ring; the status item can take a moment to appear.
                if waits < 10 { self.openPopoverForLink(waits: waits + 1, clicks: clicks, delay: 0.25) }
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            button.performClick(nil)
            // Check once whether it stayed open; reopen if it didn't.
            if clicks == 0 { self.openPopoverForLink(waits: waits, clicks: 1, delay: 0.8) }
        }
    }

    /// tel:+1-431-334-7050 -> "(431) 334-7050"; sip:alice@example.com -> "sip:alice@example.com".
    static func callLinkTarget(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), callLinkSchemes.contains(scheme) else { return nil }
        var rest = String(url.absoluteString.dropFirst(scheme.count + 1))
        rest = rest.removingPercentEncoding ?? rest
        if rest.hasPrefix("//") { rest.removeFirst(2) } // callto://…
        if let semicolon = rest.firstIndex(of: ";") { rest = String(rest[..<semicolon]) } // ;ext=, ;phone-context=
        if let question = rest.firstIndex(of: "?") { rest = String(rest[..<question]) }
        rest = rest.trimmingCharacters(in: .whitespaces)
        if PhoneFormat.looksLikeNumber(rest) {
            return PhoneFormat.display(rest) ?? rest
        }
        // SIP addresses: keep the scheme so liblinphone treats it as an address.
        return (scheme == "sip" || scheme == "sips") ? "\(scheme):\(rest)" : rest
    }

    /// Ask macOS to send call links to Ring (macOS asks the user to confirm).
    func makeDefaultForCallLinks(_ done: @escaping @MainActor (String?) -> Void) {
        let app = Bundle.main.bundleURL
        Task { @MainActor in
            var firstError: String?
            for scheme in Self.callLinkSchemes {
                do {
                    try await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: scheme)
                } catch {
                    if firstError == nil { firstError = error.localizedDescription }
                }
            }
            done(firstError)
        }
    }

    /// Whether Ring currently opens tel: links.
    var isDefaultForCallLinks: Bool {
        guard let url = URL(string: "tel:1"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: url) else { return false }
        return handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    /// Dismiss the error shown under the number field (e.g. when the field is cleared).
    func clearError() {
        lastError = nil
    }

    /// While a call is ringing and the popover is closed, the menu bar icon is a green
    /// "answer" button; opening the popover by clicking it answers the call.
    func popoverVisibilityChanged(_ open: Bool) {
        let wasOpen = popoverOpen
        popoverOpen = open
        if open, !wasOpen, case .incoming = callPhase {
            answer()
        }
    }

    /// The menu bar shows the green answer button (rather than the normal icon).
    var showsAnswerButton: Bool {
        if case .incoming = callPhase, !popoverOpen { return true }
        return false
    }

    func toggleMute() {
        isMuted.toggle()
        core.micEnabled = !isMuted
    }

    func sendDTMF(_ digit: Character) {
        guard case .active = callPhase, let ascii = digit.asciiValue, let call = currentCall else { return }
        try? call.sendDtmf(dtmf: CChar(ascii))
        core.playDtmf(dtmf: CChar(ascii), durationMs: 150) // local feedback tone
    }

    private func handleCall(_ call: Call, state: Call.State, message: String) {
        if state == .IncomingReceived {
            // Switched off (or no account): don't ring. A server can still route a call to us
            // if our un-registration never reached it.
            if !wantsConnection || activeAccount == nil {
                try? call.decline(reason: .TemporarilyUnavailable)
                return
            }
            syncRegistration() // a call arriving means the status should reflect the real state
        }
        // Adopt a new call only when none is being shown; otherwise ignore other calls.
        if trackedCall == nil, callPhase == .idle,
           [.IncomingReceived, .IncomingEarlyMedia, .OutgoingInit, .OutgoingProgress].contains(state) {
            trackedCall = call
        }
        guard let tracked = trackedCall, call === tracked else { return }

        let remote = call.remoteAddress.map(Self.displayName) ?? "Unknown"
        switch state {
        case .IncomingReceived, .IncomingEarlyMedia:
            if callPhase == .idle { lastError = nil }
            // Prefill the number field with the caller, so it's there to call back
            // whether the call is answered, declined or missed.
            if state == .IncomingReceived, let address = call.remoteAddress {
                dialTarget = Self.callbackTarget(address)
                // The popover already shows the call when it's open; only notify otherwise.
                if !popoverOpen { notifier.showIncoming(from: remote) }
            }
            callPhase = .incoming(remote: remote)
        case .OutgoingInit, .OutgoingProgress, .OutgoingRinging, .OutgoingEarlyMedia:
            callPhase = .outgoing(remote: remote)
        case .Connected, .StreamsRunning:
            notifier.clear()
            lastError = nil
            if case .active = callPhase { break }
            let start = Date()
            callPhase = .active(remote: remote, since: start)
            clock.start(since: start)
        case .Error where Self.isNetworkFailure(call):
            lastError = "Call dropped: network problem"
            endCall()
        case .End where Self.isNetworkFailure(call):
            lastError = "Call dropped: network problem"
            endCall()
        case .Error:
            let reason = Self.callFailure(call.errorInfo, message: message)
            lastError = call.dir == .Incoming ? "Incoming call from \(remote) failed: \(reason)"
                                              : "Call failed: \(reason)"
            endCall()
        case .End, .Released:
            endCall()
        default:
            break
        }
    }

    /// Standard SIP reason with its code, e.g. "Forbidden (403)".
    private static func callFailure(_ info: ErrorInfo?, message: String) -> String {
        let code = info?.protocolCode ?? 0
        let standard: [Int: String] = [
            403: "Forbidden", 404: "Not Found", 408: "Request Timeout", 480: "Temporarily Unavailable",
            484: "Address Incomplete", 486: "Busy", 488: "Not Acceptable", 500: "Server Error",
            503: "Service Unavailable", 600: "Busy", 603: "Declined", 606: "Not Acceptable",
        ]
        let phrase = standard[code]
            ?? (info?.phrase).flatMap { $0.isEmpty ? nil : $0 }
            ?? (message.isEmpty ? "Unknown error" : message)
        return code > 0 ? "\(phrase) (\(code))" : phrase
    }

    /// liblinphone ends a call with an I/O-type reason when the network failed, including when
    /// no audio arrived for `nortpTimeout` seconds (30 s by default).
    private static func isNetworkFailure(_ call: Call) -> Bool {
        let reason = call.errorInfo?.reason ?? call.reason
        return [.IOError, .NoResponse, .ServerTimeout].contains(reason)
    }

    private func endCall() {
        trackedCall = nil // its later Released (or anything else) is ignored
        clock.stop()
        notifier.clear()
        if accountApplyPending {
            // Let the BYE / its 200 OK go out before tearing down the account.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.applyPendingAccount()
            }
        }
        callPhase = .idle
        if isMuted { isMuted = false; core.micEnabled = true }
    }

    private func requestMicAccess(_ done: @escaping @MainActor (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in done(granted) }
            }
        default: done(false)
        }
    }

    /// What to put in the number field to call this address back: just the number for phone
    /// numbers (e.g. sip:4313347050@…), otherwise user@domain.
    private static func callbackTarget(_ a: Address) -> String {
        guard let user = a.username, !user.isEmpty else { return a.asStringUriOnly() }
        if PhoneFormat.looksLikeNumber(user) {
            // Prefer the display name when it's the full number (e.g. "+14313347050"
            // <sip:4313347050@…>), so the country is known; format it for the field.
            if let name = a.displayName, name.hasPrefix("+"), let formatted = PhoneFormat.display(name) {
                return formatted
            }
            return PhoneFormat.display(user) ?? user
        }
        if let domain = a.domain, !domain.isEmpty { return "\(user)@\(domain)" }
        return user
    }

    private static func displayName(_ a: Address) -> String {
        if let n = a.displayName, !n.isEmpty { return PhoneFormat.display(n) ?? n }
        if let u = a.username, let formatted = PhoneFormat.display(u) { return formatted }
        if let u = a.username, let d = a.domain { return "\(u)@\(d)" }
        return a.asStringUriOnly()
    }
}
