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
    /// Latest pointer total applied, from either the datagram or the stream path.
    var pointerSequence: UInt64 = 0
    var pointerX = 0.0
    var pointerY = 0.0

    init(connection: FramedConnection) {
        self.connection = connection
    }
}

/// Receiver mode: advertises over Bonjour, accepts paired emitters and replays their input.
final class ReceiverController: ObservableObject {
    static let pairingWindow: TimeInterval = 120
    private static let handshakeTimeout: TimeInterval = 10
    private static let silenceTimeout: TimeInterval = 8
    private static let maxDatagramFlows = 16

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
    private var datagramListener: NWListener?
    /// One flow per emitter address and port; each emitter reconnect opens a new one.
    private var datagramFlows: [NWConnection] = []
    private var sessions: [InboundSession] = []
    private var streamingSession: InboundSession?
    private var timer: Timer?

    init(identity: Identity, store: PeerStore) {
        self.identity = identity
        self.store = store
    }

    func start() {
        injector.onEdgeExit = { [weak self] position in
            guard let self, let session = self.streamingSession else { return }
            self.send(.edgeExit(position: position), to: session)
        }
        startListener()
        startDatagramListener()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    func stop() {
        timer?.invalidate()
        listener?.cancel()
        listener = nil
        datagramListener?.cancel()
        datagramListener = nil
        datagramFlows.forEach { $0.cancel() }
        datagramFlows = []
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

    /// UDP on the same port as the stream. If it can't start, emitters still get
    /// pointer updates over the stream every 100 ms.
    private func startDatagramListener() {
        do {
            let listener = try NWListener(using: NetworkConfig.datagramParameters(), on: NWEndpoint.Port(rawValue: NetworkConfig.defaultPort)!)
            listener.newConnectionHandler = { [weak self] flow in self?.acceptDatagrams(flow) }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state { NSLog("ToggleMouse: UDP listener failed: \(error)") }
            }
            listener.start(queue: .main)
            datagramListener = listener
        } catch {
            NSLog("ToggleMouse: UDP listener failed: \(error)")
        }
    }

    private func acceptDatagrams(_ flow: NWConnection) {
        if datagramFlows.count >= Self.maxDatagramFlows {
            datagramFlows.removeFirst().cancel()
        }
        datagramFlows.append(flow)
        flow.stateUpdateHandler = { [weak self, weak flow] state in
            switch state {
            case .failed, .cancelled:
                self?.datagramFlows.removeAll { $0 === flow }
            default:
                break
            }
        }
        flow.start(queue: .main)
        receiveDatagram(on: flow)
    }

    private func receiveDatagram(on flow: NWConnection) {
        flow.receiveMessage { [weak self, weak flow] data, _, _, error in
            guard let self, let flow, error == nil else { return }
            if let data { self.received(datagram: data) }
            self.receiveDatagram(on: flow)
        }
    }

    private func received(datagram: Data) {
        guard let id = SecureChannel.datagramID(of: datagram),
              let session = sessions.first(where: { $0.isAuthenticated && $0.channel?.datagramID == id }),
              let message = try? session.channel?.openDatagram(datagram),
              case .pointer = message else { return }
        handle(message, from: session, viaDatagram: true)
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

    private func handle(_ message: StreamMessage, from session: InboundSession, viaDatagram: Bool = false) {
        let arrivedAt = Int64(DispatchTime.now().uptimeNanoseconds)
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
            injector.beginPointer(x: session.pointerX, y: session.pointerY)
        case .end:
            if streamingSession === session { endStream() }
        case let .placement(side, entry):
            if streamingSession === session { injector.place(side: side, entry: entry) }
        case let .pointer(sequence, x, y, time):
            // Datagrams and stream syncs interleave; only newer totals count.
            guard sequence > session.pointerSequence else { break }
            session.pointerSequence = sequence
            session.pointerX = x
            session.pointerY = y
            if streamingSession === session {
                injector.pointer(x: x, y: y, sentAt: Int64(clamping: time), arrivedAt: arrivedAt, viaDatagram: viaDatagram)
            }
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
