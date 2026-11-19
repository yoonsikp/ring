import Foundation
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
    /// User intent: whether we *want* to be registered (the menu's Connect/Disconnect toggle).
    @Published private(set) var wantsConnection = true
    /// liblinphone's own network monitoring (it closes connections when the network goes and
    /// reconnects / re-registers by itself when it comes back).
    @Published private(set) var networkReachable = true
    /// Account changes (disconnect switch, new settings) wait until the current call has ended.
    private var accountApplyPending = false

    private var core: Core!
    private var delegate: CoreDelegateStub!
    private var iterateTimer: Timer?
    /// nil until first set; true while a call is ringing/active or we're registering.
    private var isBusy: Bool?
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

        // We drive the core ourselves; the rate depends on whether a call is going on.
        core.autoIterateEnabled = false

        do { try core.start() } catch { lastError = "Core start failed: \(error)" }
        applyAudio()
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
            MainActor.assumeIsolated { self?.core.iterate() }
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
        let changed = new != settings
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
        applyAccount()
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
        case .Ok: registration = .connected
        case .Progress: registration = .connecting
        case .Failed: registration = .failed(Self.registrationFailure(account.errorInfo, message: message))
        case .Cleared, .None: registration = .disconnected
        default: break // e.g. Refreshing: keep current state
        }
    }

    // MARK: - Calls

    /// The one call the UI is showing. Events from any other call (an old call's late
    /// Released, or a second INVITE auto-rejected as busy) must not change the UI.
    private var trackedCall: Call?
    private var currentCall: Call? { trackedCall }

    func dial(_ input: String) {
        let target = input.trimmingCharacters(in: .whitespaces)
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
            callPhase = .incoming(remote: remote)
        case .OutgoingInit, .OutgoingProgress, .OutgoingRinging, .OutgoingEarlyMedia:
            callPhase = .outgoing(remote: remote)
        case .Connected, .StreamsRunning:
            lastError = nil
            if case .active = callPhase { break }
            callPhase = .active(remote: remote, since: Date())
        case .Error where Self.isNetworkFailure(call):
            lastError = "Call dropped: network problem"
            endCall()
        case .End where Self.isNetworkFailure(call):
            lastError = "Call dropped: network problem"
            endCall()
        case .Error:
            if call.dir == .Incoming {
                lastError = "Incoming call from \(remote) failed: \(message.isEmpty ? "unknown reason" : message)"
            } else {
                lastError = message.isEmpty ? "Call failed" : message
            }
            endCall()
        case .End, .Released:
            endCall()
        default:
            break
        }
    }

    /// liblinphone ends a call with an I/O-type reason when the network failed, including when
    /// no audio arrived for `nortpTimeout` seconds (30 s by default).
    private static func isNetworkFailure(_ call: Call) -> Bool {
        let reason = call.errorInfo?.reason ?? call.reason
        return [.IOError, .NoResponse, .ServerTimeout].contains(reason)
    }

    private func endCall() {
        trackedCall = nil // its later Released (or anything else) is ignored
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

    private static func displayName(_ a: Address) -> String {
        if let n = a.displayName, !n.isEmpty { return n }
        if let u = a.username, let d = a.domain { return "\(u)@\(d)" }
        return a.asStringUriOnly()
    }
}
