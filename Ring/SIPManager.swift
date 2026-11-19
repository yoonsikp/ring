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

    @Published private(set) var registration: Registration = .disconnected
    @Published private(set) var callPhase: CallPhase = .idle
    @Published private(set) var isMuted = false
    /// Digits the other side pressed during the current call.
    @Published private(set) var receivedDigits = ""
    @Published private(set) var lastError: String?
    @Published private(set) var settings = AccountSettings.load()
    /// User intent: whether we *want* to be registered (the menu's Connect/Disconnect toggle).
    @Published private(set) var wantsConnection = true

    private var core: Core!
    private var delegate: CoreDelegateStub!
    private var iterateTimer: Timer?
    /// The single account we created; events from previously removed accounts are ignored.
    private var activeAccount: Account?
    /// Keeps App Nap from throttling us, so we keep the SIP connection alive and hear incoming calls.
    private var activity: NSObjectProtocol?

    /// liblinphone logs go here (~/Library/Logs/Ring).
    static let logDirectory: URL = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Ring", isDirectory: true)

    init() {
        try? FileManager.default.createDirectory(at: Self.logDirectory, withIntermediateDirectories: true)
        Core.setLogCollectionPath(path: Self.logDirectory.path)
        Core.enableLogCollection(state: .Enabled)
        LoggingService.Instance.logLevel = .Message

        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Listening for incoming SIP calls")

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
        try? core.setMediaencryption(newValue: .SRTP)
        core.mediaEncryptionMandatory = true   // refuse calls that can't do SRTP

        delegate = CoreDelegateStub(
            onCallStateChanged: { [weak self] _, call, state, message in
                MainActor.assumeIsolated { self?.handleCall(call, state: state, message: message) }
            },
            onDtmfReceived: { [weak self] _, _, dtmf in
                MainActor.assumeIsolated { self?.handleReceivedDTMF(dtmf) }
            },
            onAccountRegistrationStateChanged: { [weak self] _, account, state, message in
                MainActor.assumeIsolated { self?.handleRegistration(account, state: state, message: message) }
            }
        )
        core.addDelegate(delegate: delegate)

        // Drive the core ourselves on the main run loop (in .common mode so it keeps
        // running while the menu is open).
        core.autoIterateEnabled = false
        let timer = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.core.iterate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        iterateTimer = timer

        do { try core.start() } catch { lastError = "Core start failed: \(error)" }
        applyAccount()
    }

    func shutdown() {
        try? core.terminateAllCalls()
        core.stop()
        iterateTimer?.invalidate()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }

    // MARK: - Account

    func update(settings new: AccountSettings) {
        new.save()
        var oldAccount = settings, newAccount = new
        // Audio preferences don't need a re-registration.
        oldAccount.echoCancellation = false; newAccount.echoCancellation = false
        oldAccount.playReceivedDTMF = false; newAccount.playReceivedDTMF = false
        settings = new
        core.echoCancellationEnabled = new.echoCancellation // takes effect from the next call
        if oldAccount != newAccount { applyAccount() }       // only re-register if the account changed
    }

    func setConnected(_ on: Bool) {
        wantsConnection = on
        applyAccount()
    }

    /// Tear down whatever account exists and (re)create the single configured one.
    private func applyAccount() {
        lastError = nil
        core.echoCancellationEnabled = settings.echoCancellation
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

    private func handleRegistration(_ account: Account, state: RegistrationState, message: String) {
        guard let active = activeAccount, account === active else { return }
        switch state {
        case .Ok: registration = .connected
        case .Progress: registration = .connecting
        case .Failed: registration = .failed(message.isEmpty ? "Registration failed" : message)
        case .Cleared, .None: registration = .disconnected
        default: break // e.g. Refreshing: keep current state
        }
    }

    // MARK: - Calls

    private var currentCall: Call? { core.currentCall ?? core.calls.first }

    func dial(_ input: String) {
        let target = input.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty, callPhase == .idle else { return }
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
                if self.core.inviteAddressWithParams(addr: addr, params: params) == nil {
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

    /// The remote side's DTMF arrives as RTP telephone-events (RFC 2833) or SIP INFO, which
    /// liblinphone strips from the audio. Show the digit, and play its tone locally if enabled.
    private func handleReceivedDTMF(_ dtmf: Int) {
        guard dtmf > 0, dtmf < 128, let scalar = Unicode.Scalar(UInt32(dtmf)), "0123456789*#ABCD".unicodeScalars.contains(scalar) else { return }
        if settings.playReceivedDTMF {
            core.playDtmf(dtmf: CChar(dtmf), durationMs: 200)
        }
        receivedDigits.append(Character(scalar))
    }

    private func handleCall(_ call: Call, state: Call.State, message: String) {
        let remote = call.remoteAddress.map(Self.displayName) ?? "Unknown"
        switch state {
        case .IncomingReceived, .IncomingEarlyMedia:
            callPhase = .incoming(remote: remote)
        case .OutgoingInit, .OutgoingProgress, .OutgoingRinging, .OutgoingEarlyMedia:
            callPhase = .outgoing(remote: remote)
        case .Connected, .StreamsRunning:
            if case .active = callPhase { break }
            callPhase = .active(remote: remote, since: Date())
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

    private func endCall() {
        callPhase = .idle
        receivedDigits = ""
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
