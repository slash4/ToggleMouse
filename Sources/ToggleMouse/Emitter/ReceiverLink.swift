import CryptoKit
import Foundation
import Network

/// Persistent authenticated connection from the emitter to one paired receiver.
/// Kept open while idle so toggling is instant; `tick()` drives reconnects and heartbeats.
final class ReceiverLink {
    enum State {
        case disconnected, connecting, connected
    }

    private static let connectTimeout: TimeInterval = 5
    private static let heartbeatInterval: TimeInterval = 2
    private static let silenceTimeout: TimeInterval = 6
    private static let retryDelay: TimeInterval = 2
    private static let rejectedRetryDelay: TimeInterval = 30
    /// How often the pointer total also goes over the stream, in case UDP is blocked.
    private static let pointerSyncInterval: TimeInterval = 0.1

    var peer: PairedPeer
    var onStateChange: ((State) -> Void)?
    var onError: ((String) -> Void)?
    /// Heartbeat round-trip time, reported after each echo.
    var onRoundTrip: ((TimeInterval) -> Void)?

    private(set) var state: State = .disconnected {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    private let identity: Identity
    private var connection: FramedConnection?
    private var channel: SecureChannel?
    private var ephemeral: Curve25519.KeyAgreement.PrivateKey?
    private var connectStarted = Date.distantPast
    private var lastReceived = Date.distantPast
    /// Heartbeats go out on a fixed schedule, even while input traffic is flowing,
    /// because the receiver only sends anything back when it echoes one.
    private var lastHeartbeat = Date.distantPast
    private var nextAttempt = Date.distantPast

    /// Pointer movement goes by UDP as a running total: a lost datagram costs nothing
    /// because the next one carries the full total.
    private var datagrams: NWConnection?
    private var pointerSequence: UInt64 = 0
    private var syncedPointerSequence: UInt64 = 0
    private var pointerX = 0.0
    private var pointerY = 0.0
    private var lastPointerSync = Date.distantPast

    init(peer: PairedPeer, identity: Identity) {
        self.peer = peer
        self.identity = identity
    }

    func tick(endpoint: NWEndpoint?) {
        let now = Date()
        switch state {
        case .disconnected:
            if let endpoint, now >= nextAttempt { connect(to: endpoint) }
        case .connecting:
            if now.timeIntervalSince(connectStarted) > Self.connectTimeout { close() }
        case .connected:
            if now.timeIntervalSince(lastReceived) > Self.silenceTimeout {
                close()
            } else if now.timeIntervalSince(lastHeartbeat) >= Self.heartbeatInterval {
                send(.heartbeat)
                lastHeartbeat = now
            }
        }
    }

    /// Retries on the next tick instead of waiting out the backoff.
    func retrySoon() {
        nextAttempt = .distantPast
    }

    func send(_ message: StreamMessage) {
        guard let channel, let connection, let frame = try? channel.seal(message) else { return }
        connection.send(frame)
    }

    func movePointer(dx: Double, dy: Double) {
        guard let channel else { return }
        pointerX += dx
        pointerY += dy
        pointerSequence += 1
        let message = StreamMessage.pointer(sequence: pointerSequence, x: pointerX, y: pointerY)
        if let datagrams, let datagram = try? channel.sealDatagram(message, sequence: pointerSequence) {
            datagrams.send(content: datagram, completion: .idempotent)
        }
        if Date().timeIntervalSince(lastPointerSync) >= Self.pointerSyncInterval {
            syncPointer()
        }
    }

    /// Sends the latest pointer total over the stream, so a click or scroll that
    /// follows lands where the cursor is even if datagrams were lost.
    func syncPointer() {
        guard pointerSequence > syncedPointerSequence else { return }
        send(.pointer(sequence: pointerSequence, x: pointerX, y: pointerY))
        syncedPointerSequence = pointerSequence
        lastPointerSync = Date()
    }

    func close() {
        connection?.close()
    }

    private func connect(to endpoint: NWEndpoint) {
        let connection = FramedConnection(endpoint: endpoint)
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        self.connection = connection
        self.ephemeral = ephemeral
        channel = nil
        connectStarted = Date()
        nextAttempt = Date().addingTimeInterval(Self.retryDelay)
        state = .connecting

        let hello = ControlMessage.sessionHello(
            deviceID: identity.deviceID,
            name: identity.name,
            staticKey: identity.publicKey,
            ephemeralKey: ephemeral.publicKey.rawRepresentation
        )
        connection.onReady = { [weak connection] in connection?.send(hello.encoded()) }
        connection.onFrame = { [weak self] frame in self?.received(frame) }
        connection.onClose = { [weak self] _ in self?.closed() }
        connection.start()
    }

    private func received(_ frame: Data) {
        if let channel {
            guard let message = try? channel.open(frame) else {
                close()
                return
            }
            lastReceived = Date()
            switch message {
            case .ready where state == .connecting:
                openDatagrams()
                state = .connected
            case .heartbeat:
                onRoundTrip?(lastReceived.timeIntervalSince(lastHeartbeat))
            default:
                break
            }
            return
        }

        switch ControlMessage.decode(frame) {
        case let .sessionAccept(deviceID, staticKey, ephemeralKey):
            guard deviceID == peer.id, staticKey == peer.publicKey, let ephemeral,
                  let channel = try? SecureChannel.establish(
                      isInitiator: true,
                      localStatic: identity.privateKey,
                      localEphemeral: ephemeral,
                      remoteStatic: staticKey,
                      remoteEphemeral: ephemeralKey
                  ) else {
                onError?("\(peer.name) presented an unexpected key. Re-pair if it was reinstalled.")
                nextAttempt = Date().addingTimeInterval(Self.rejectedRetryDelay)
                close()
                return
            }
            self.channel = channel
            // Proves we derived the same keys; the receiver answers with its own .ready.
            send(.ready)
        case let .rejected(reason):
            onError?("\(peer.name): \(reason)")
            nextAttempt = Date().addingTimeInterval(Self.rejectedRetryDelay)
            close()
        default:
            close()
        }
    }

    /// Datagrams go to the same address and port as the stream.
    private func openDatagrams() {
        guard case let .hostPort(host, port) = connection?.remoteEndpoint else { return }
        let datagrams = NWConnection(host: host, port: port, using: NetworkConfig.datagramParameters())
        datagrams.start(queue: .main)
        self.datagrams = datagrams
    }

    private func closed() {
        connection = nil
        channel = nil
        ephemeral = nil
        datagrams?.cancel()
        datagrams = nil
        pointerSequence = 0
        syncedPointerSequence = 0
        pointerX = 0
        pointerY = 0
        state = .disconnected
    }
}
