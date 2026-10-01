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

    var peer: PairedPeer
    var onStateChange: ((State) -> Void)?
    var onError: ((String) -> Void)?

    private(set) var state: State = .disconnected {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    private let identity: Identity
    private var connection: FramedConnection?
    private var channel: SecureChannel?
    private var ephemeral: Curve25519.KeyAgreement.PrivateKey?
    private var connectStarted = Date.distantPast
    private var lastReceived = Date.distantPast
    private var lastSent = Date.distantPast
    private var nextAttempt = Date.distantPast

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
            } else if now.timeIntervalSince(lastSent) >= Self.heartbeatInterval {
                send(.heartbeat)
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
        lastSent = Date()
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
            if message == .ready, state == .connecting {
                state = .connected
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

    private func closed() {
        connection = nil
        channel = nil
        ephemeral = nil
        state = .disconnected
    }
}
