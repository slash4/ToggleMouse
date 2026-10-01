import Foundation
import Network

/// One pairing attempt, run identically on both Macs apart from who speaks first.
///
///     emitter (initiator)                         receiver (responder)
///     pairRequest(id, name, H(key‖nonce))  ──▶
///                                          ◀──  pairResponse(id, name, key, nonce)
///     pairReveal(key, nonce)               ──▶  checks commitment
///     both show the same 6-digit code; the user confirms on each Mac
///     pairConfirm(true)                    ◀─▶  pairConfirm(true)
///
/// Each side stores the other's key only once both users have confirmed.
final class PairingSession: ObservableObject, Identifiable {
    enum Phase: Equatable {
        case connecting
        case comparing(code: String)
        case waitingForPeer
        case succeeded
        case failed(String)

        var isFinished: Bool {
            switch self {
            case .succeeded, .failed: return true
            default: return false
            }
        }
    }

    @Published private(set) var phase: Phase = .connecting
    @Published private(set) var peerName: String

    /// Called once with the newly paired peer.
    var onComplete: ((PairedPeer) -> Void)?

    private let isInitiator: Bool
    private let identity: Identity
    private let connection: FramedConnection
    private let nonce = randomBytes(PairingCrypto.nonceSize)
    private var peerID = ""
    private var peerKey = Data()
    private var peerNonce = Data()
    private var peerCommitment = Data()
    private var localConfirmed = false
    private var remoteConfirmed = false

    /// Emitter side: connects to a receiver and opens the exchange.
    init(connectingTo endpoint: NWEndpoint, peerName: String, identity: Identity) {
        isInitiator = true
        self.identity = identity
        self.peerName = peerName
        connection = FramedConnection(endpoint: endpoint)
        attach()
        connection.onReady = { [weak self] in
            guard let self else { return }
            let commitment = PairingCrypto.commitment(publicKey: identity.publicKey, nonce: self.nonce)
            self.connection.send(ControlMessage.pairRequest(deviceID: identity.deviceID, name: identity.name, commitment: commitment).encoded())
        }
        connection.start()
    }

    /// Receiver side: takes over a connection whose first frame was a pair request.
    init(accepting connection: FramedConnection, deviceID: String, name: String, commitment: Data, identity: Identity) {
        isInitiator = false
        self.identity = identity
        self.connection = connection
        peerName = name
        peerID = deviceID
        peerCommitment = commitment
        attach()
        guard commitment.count == 32, deviceID != identity.deviceID else {
            fail("Invalid pairing request")
            return
        }
        connection.send(ControlMessage.pairResponse(
            deviceID: identity.deviceID, name: identity.name, publicKey: identity.publicKey, nonce: nonce
        ).encoded())
    }

    func confirm() {
        guard case .comparing = phase else { return }
        localConfirmed = true
        connection.send(ControlMessage.pairConfirm(accepted: true).encoded())
        phase = .waitingForPeer
        finishIfReady()
    }

    func cancel() {
        guard !phase.isFinished else { return }
        connection.send(ControlMessage.pairConfirm(accepted: false).encoded())
        fail("Pairing cancelled")
    }

    private func attach() {
        connection.onFrame = { [weak self] frame in self?.received(frame) }
        connection.onClose = { [weak self] reason in self?.fail(reason ?? "Connection closed") }
    }

    private func received(_ frame: Data) {
        guard let message = ControlMessage.decode(frame) else {
            fail("Unexpected message")
            return
        }
        switch (isInitiator, message) {
        case let (true, .pairResponse(deviceID, name, publicKey, nonce)):
            guard peerKey.isEmpty, deviceID != identity.deviceID,
                  publicKey.count == PairingCrypto.keySize, nonce.count == PairingCrypto.nonceSize else {
                fail("Invalid pairing response")
                return
            }
            peerID = deviceID
            peerName = name
            peerKey = publicKey
            peerNonce = nonce
            connection.send(ControlMessage.pairReveal(publicKey: identity.publicKey, nonce: self.nonce).encoded())
            showCode()
        case let (false, .pairReveal(publicKey, nonce)):
            guard peerKey.isEmpty, publicKey.count == PairingCrypto.keySize, nonce.count == PairingCrypto.nonceSize,
                  PairingCrypto.commitment(publicKey: publicKey, nonce: nonce) == peerCommitment else {
                fail("Commitment check failed. Someone may be intercepting the connection.")
                return
            }
            peerKey = publicKey
            peerNonce = nonce
            showCode()
        case let (_, .pairConfirm(accepted)):
            guard accepted, !peerKey.isEmpty else {
                fail("Pairing was declined on \(peerName)")
                return
            }
            remoteConfirmed = true
            finishIfReady()
        case let (_, .rejected(reason)):
            fail(reason)
        default:
            fail("Unexpected message")
        }
    }

    private func showCode() {
        let code = isInitiator
            ? PairingCrypto.verificationCode(initiatorKey: identity.publicKey, responderKey: peerKey, initiatorNonce: nonce, responderNonce: peerNonce)
            : PairingCrypto.verificationCode(initiatorKey: peerKey, responderKey: identity.publicKey, initiatorNonce: peerNonce, responderNonce: nonce)
        phase = .comparing(code: code)
    }

    private func finishIfReady() {
        guard localConfirmed, remoteConfirmed, !phase.isFinished else { return }
        phase = .succeeded
        onComplete?(PairedPeer(id: peerID, name: peerName, publicKey: peerKey))
        // Give the final confirm frame time to flush before closing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [connection] in connection.close() }
    }

    private func fail(_ reason: String) {
        guard !phase.isFinished else { return }
        phase = .failed(reason)
        connection.close()
    }
}
