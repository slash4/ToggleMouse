import CryptoKit
import Foundation
import Network

/// One incoming connection from an emitter, from first frame through handshake to streaming.
private final class InboundSession {
    let connection: FramedConnection
    let opened = Date()
    var lastReceived = Date()
    var peer: PairedPeer?
    var channel: SecureChannel?
    /// True once the emitter has proven it derived the same session keys.
    var isAuthenticated = false

    init(connection: FramedConnection) {
        self.connection = connection
    }
}

/// Receiver mode: advertises over Bonjour, accepts paired emitters and replays their input.
final class ReceiverController: ObservableObject {
    static let pairingWindow: TimeInterval = 120
    private static let handshakeTimeout: TimeInterval = 10
    private static let silenceTimeout: TimeInterval = 8

    @Published private(set) var listenerStatus = "Starting…"
    @Published private(set) var pairingOpenUntil: Date?
    @Published private(set) var pairing: PairingSession?
    @Published private(set) var connectedEmitterIDs: Set<String> = []
    @Published private(set) var streamingEmitterID: String?

    /// Called when an emitter asks to pair, so the prompt can be brought to the front.
    var onPairingRequest: (() -> Void)?

    private let identity: Identity
    private let store: PeerStore
    private let injector = EventInjector()
    private var listener: NWListener?
    private var sessions: [InboundSession] = []
    private var streamingSession: InboundSession?
    private var timer: Timer?

    init(identity: Identity, store: PeerStore) {
        self.identity = identity
        self.store = store
    }

    func start() {
        startListener()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    func stop() {
        timer?.invalidate()
        listener?.cancel()
        listener = nil
        sessions.forEach { $0.connection.close() }
        pairing?.cancel()
        endStream()
    }

    // MARK: Pairing

    func openPairing() {
        pairingOpenUntil = Date().addingTimeInterval(Self.pairingWindow)
    }

    func closePairing() {
        pairingOpenUntil = nil
    }

    func dismissPairing() {
        pairing?.cancel()
        pairing = nil
    }

    func unpair(_ emitterID: String) {
        store.emitters.removeAll { $0.id == emitterID }
        for session in sessions where session.peer?.id == emitterID {
            session.connection.close()
        }
    }

    private var isPairingOpen: Bool {
        guard let until = pairingOpenUntil else { return false }
        return until > Date()
    }

    // MARK: Connections

    private func startListener() {
        do {
            let listener = try NWListener(using: NetworkConfig.parameters(), on: NWEndpoint.Port(rawValue: NetworkConfig.defaultPort)!)
            listener.service = NWListener.Service(
                name: identity.name,
                type: NetworkConfig.serviceType,
                txtRecord: NWTXTRecord(["id": identity.deviceID])
            )
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.listenerStatus = "Listening on port \(NetworkConfig.defaultPort)"
                case .waiting(let error), .failed(let error):
                    self.listenerStatus = "Listener error: \(error.localizedDescription). Retrying…"
                    self.listener?.cancel()
                    self.listener = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                        guard let self, self.timer?.isValid == true, self.listener == nil else { return }
                        self.startListener()
                    }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            listenerStatus = "Listener error: \(error.localizedDescription)"
        }
    }

    private func accept(_ nwConnection: NWConnection) {
        let session = InboundSession(connection: FramedConnection(nwConnection))
        sessions.append(session)
        session.connection.onFrame = { [weak self, weak session] frame in
            guard let self, let session else { return }
            self.received(frame, on: session)
        }
        session.connection.onClose = { [weak self, weak session] _ in
            guard let self, let session else { return }
            self.closed(session)
        }
        session.connection.start()
    }

    private func received(_ frame: Data, on session: InboundSession) {
        session.lastReceived = Date()
        if let channel = session.channel {
            guard let message = try? channel.open(frame) else {
                session.connection.close()
                return
            }
            handle(message, from: session)
            return
        }

        switch ControlMessage.decode(frame) {
        case let .pairRequest(deviceID, name, commitment):
            startPairing(session, deviceID: deviceID, name: name, commitment: commitment)
        case let .sessionHello(deviceID, _, staticKey, ephemeralKey):
            guard let peer = store.emitters.first(where: { $0.id == deviceID }), peer.publicKey == staticKey else {
                reject(session, reason: "this Mac is not paired with \(identity.name). Pair again.")
                return
            }
            let ephemeral = Curve25519.KeyAgreement.PrivateKey()
            guard let channel = try? SecureChannel.establish(
                isInitiator: false,
                localStatic: identity.privateKey,
                localEphemeral: ephemeral,
                remoteStatic: staticKey,
                remoteEphemeral: ephemeralKey
            ) else {
                session.connection.close()
                return
            }
            session.peer = peer
            session.channel = channel
            session.connection.send(ControlMessage.sessionAccept(
                deviceID: identity.deviceID,
                staticKey: identity.publicKey,
                ephemeralKey: ephemeral.publicKey.rawRepresentation
            ).encoded())
        default:
            session.connection.close()
        }
    }

    private func handle(_ message: StreamMessage, from session: InboundSession) {
        guard session.isAuthenticated else {
            guard message == .ready else {
                session.connection.close()
                return
            }
            session.isAuthenticated = true
            send(.ready, to: session)
            refreshConnected()
            return
        }
        switch message {
        case .ready:
            break
        case .heartbeat:
            send(.heartbeat, to: session)
        case .begin:
            endStream()
            streamingSession = session
            streamingEmitterID = session.peer?.id
        case .end:
            if streamingSession === session { endStream() }
        default:
            if streamingSession === session { injector.apply(message) }
        }
    }

    private func send(_ message: StreamMessage, to session: InboundSession) {
        guard let frame = try? session.channel?.seal(message) else { return }
        session.connection.send(frame)
    }

    private func endStream() {
        guard streamingSession != nil else { return }
        injector.releaseAll()
        streamingSession = nil
        streamingEmitterID = nil
    }

    private func reject(_ session: InboundSession, reason: String) {
        session.connection.send(ControlMessage.rejected(reason: reason).encoded())
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { session.connection.close() }
    }

    private func startPairing(_ session: InboundSession, deviceID: String, name: String, commitment: Data) {
        guard isPairingOpen else {
            reject(session, reason: "Pairing is not enabled on \(identity.name). Click “Allow pairing” there first.")
            return
        }
        guard pairing == nil || pairing?.phase.isFinished == true else {
            reject(session, reason: "\(identity.name) is busy with another pairing")
            return
        }
        // The pairing session takes over the connection.
        sessions.removeAll { $0 === session }
        let pairing = PairingSession(
            accepting: session.connection, deviceID: deviceID, name: name, commitment: commitment, identity: identity
        )
        pairing.onComplete = { [weak self] peer in
            self?.store.addEmitter(peer)
            self?.pairingOpenUntil = nil
        }
        self.pairing = pairing
        onPairingRequest?()
    }

    private func closed(_ session: InboundSession) {
        sessions.removeAll { $0 === session }
        if streamingSession === session { endStream() }
        refreshConnected()
    }

    private func refreshConnected() {
        connectedEmitterIDs = Set(sessions.filter(\.isAuthenticated).compactMap { $0.peer?.id })
    }

    private func tick() {
        let now = Date()
        for session in sessions {
            let timedOut = session.isAuthenticated
                ? now.timeIntervalSince(session.lastReceived) > Self.silenceTimeout
                : now.timeIntervalSince(session.opened) > Self.handshakeTimeout
            if timedOut { session.connection.close() }
        }
        if let until = pairingOpenUntil, until <= now {
            pairingOpenUntil = nil
        }
    }
}
