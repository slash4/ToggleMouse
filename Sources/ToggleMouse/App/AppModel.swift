import ApplicationServices
import Combine
import Foundation

final class AppModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case emitter, receiver

        var id: Self { self }
        var title: String { self == .emitter ? "Emitter" : "Receiver" }
    }

    enum Indicator {
        case idle, emitting, receiving
    }

    @Published var mode: Mode {
        didSet {
            guard mode != oldValue else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: "mode")
            startController()
        }
    }

    @Published private(set) var indicator: Indicator = .idle
    @Published private(set) var emitter: EmitterController?
    @Published private(set) var receiver: ReceiverController?
    @Published private(set) var isTrusted = AXIsProcessTrusted()

    let identity: Identity
    let store = PeerStore()

    /// Asks the app to show its window, e.g. for an incoming pairing request.
    var onNeedsWindow: (() -> Void)?

    private var indicatorObserver: AnyCancellable?
    private var trustTimer: Timer?
    /// Keeps App Nap from throttling this background app, which would delay input handling.
    private let activity = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
        reason: "Streaming mouse and keyboard input"
    )

    init(identity: Identity) {
        self.identity = identity
        mode = UserDefaults.standard.string(forKey: "mode").flatMap(Mode.init) ?? .emitter
        startController()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let trusted = AXIsProcessTrusted()
            if trusted != self.isTrusted { self.isTrusted = trusted }
        }
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        isTrusted = AXIsProcessTrustedWithOptions(options)
    }

    func shutdown() {
        emitter?.stop()
        receiver?.stop()
    }

    private func startController() {
        shutdown()
        emitter = nil
        receiver = nil
        switch mode {
        case .emitter:
            let emitter = EmitterController(identity: identity, store: store)
            indicatorObserver = emitter.$activeReceiverID.sink { [weak self] id in
                self?.indicator = id == nil ? .idle : .emitting
            }
            emitter.start()
            self.emitter = emitter
        case .receiver:
            let receiver = ReceiverController(identity: identity, store: store)
            indicatorObserver = receiver.$streamingEmitterID.sink { [weak self] id in
                self?.indicator = id == nil ? .idle : .receiving
            }
            receiver.onPairingRequest = { [weak self] in self?.onNeedsWindow?() }
            receiver.start()
            self.receiver = receiver
        }
    }
}
