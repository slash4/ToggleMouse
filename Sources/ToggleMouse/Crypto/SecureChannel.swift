import CryptoKit
import Foundation

/// Pairing uses numeric comparison with a commitment (as in Bluetooth Secure Simple Pairing):
/// the initiator commits to its key and nonce before seeing the responder's, so a
/// man-in-the-middle cannot steer both sides to the same 6-digit code (1 in 10^6 per attempt).
enum PairingCrypto {
    static let keySize = 32
    static let nonceSize = 32

    static func commitment(publicKey: Data, nonce: Data) -> Data {
        Data(SHA256.hash(data: Data("ToggleMouse-commit-v1".utf8) + publicKey + nonce))
    }

    static func verificationCode(initiatorKey: Data, responderKey: Data, initiatorNonce: Data, responderNonce: Data) -> String {
        let input = Data("ToggleMouse-code-v1".utf8) + initiatorKey + responderKey + initiatorNonce + responderNonce
        let value = SHA256.hash(data: input).prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return String(format: "%06u", value % 1_000_000)
    }
}

enum ChannelError: Error {
    case malformed
}

/// ChaCha20-Poly1305 channel with one key per direction and counter nonces. TCP preserves
/// order, so any replayed, dropped or reordered frame fails authentication.
///
/// The session also has a one-way datagram path (emitter to receiver) for pointer updates,
/// with its own key. Datagrams carry their sequence number, which is also the nonce; the
/// receiver drops any datagram that isn't newer than the last one it accepted.
final class SecureChannel {
    private static let tagSize = 16
    static let datagramIDSize = 8
    private static let datagramHeaderSize = datagramIDSize + 8

    /// Identifies this session's datagrams; both sides derive it in the handshake.
    let datagramID: Data

    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private let datagramKey: SymmetricKey
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0
    private var lastDatagramSequence: UInt64 = 0

    init(sendKey: SymmetricKey, receiveKey: SymmetricKey, datagramKey: SymmetricKey, datagramID: Data) {
        self.sendKey = sendKey
        self.receiveKey = receiveKey
        self.datagramKey = datagramKey
        self.datagramID = datagramID
    }

    func seal(_ message: StreamMessage) throws -> Data {
        let box = try ChaChaPoly.seal(message.encoded(), using: sendKey, nonce: Self.nonce(sendCounter))
        sendCounter += 1
        return Data(box.ciphertext) + box.tag
    }

    func open(_ frame: Data) throws -> StreamMessage {
        guard frame.count >= Self.tagSize else { throw ChannelError.malformed }
        let box = try ChaChaPoly.SealedBox(
            nonce: Self.nonce(receiveCounter),
            ciphertext: frame.dropLast(Self.tagSize),
            tag: frame.suffix(Self.tagSize)
        )
        let plaintext = try ChaChaPoly.open(box, using: receiveKey)
        receiveCounter += 1
        guard let message = StreamMessage(decoding: plaintext) else { throw ChannelError.malformed }
        return message
    }

    /// `sequence` must increase with every datagram.
    func sealDatagram(_ message: StreamMessage, sequence: UInt64) throws -> Data {
        let box = try ChaChaPoly.seal(message.encoded(), using: datagramKey, nonce: Self.nonce(sequence), authenticating: datagramID)
        var header = ByteWriter()
        header.u64(sequence)
        return datagramID + header.data + Data(box.ciphertext) + box.tag
    }

    static func datagramID(of datagram: Data) -> Data? {
        guard datagram.count >= datagramHeaderSize + tagSize else { return nil }
        return Data(datagram.prefix(datagramIDSize))
    }

    func openDatagram(_ datagram: Data) throws -> StreamMessage {
        let datagram = Data(datagram)
        var header = ByteReader(datagram.subdata(in: Self.datagramIDSize..<min(Self.datagramHeaderSize, datagram.count)))
        guard datagram.count >= Self.datagramHeaderSize + Self.tagSize,
              datagram.prefix(Self.datagramIDSize) == datagramID,
              let sequence = header.u64(), sequence > lastDatagramSequence else { throw ChannelError.malformed }
        let body = datagram.subdata(in: Self.datagramHeaderSize..<datagram.count)
        let box = try ChaChaPoly.SealedBox(
            nonce: Self.nonce(sequence),
            ciphertext: body.dropLast(Self.tagSize),
            tag: body.suffix(Self.tagSize)
        )
        let plaintext = try ChaChaPoly.open(box, using: datagramKey, authenticating: datagramID)
        lastDatagramSequence = sequence
        guard let message = StreamMessage(decoding: plaintext) else { throw ChannelError.malformed }
        return message
    }

    private static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: counter.bigEndian) { bytes.append(contentsOf: $0) }
        return try! ChaChaPoly.Nonce(data: bytes)
    }

    /// Noise-KK-style key agreement between two pinned static keys plus fresh ephemerals.
    /// Only the holders of both paired private keys can derive the session keys, which
    /// authenticates both sides; the ephemerals give each session fresh keys.
    static func establish(
        isInitiator: Bool,
        localStatic: Curve25519.KeyAgreement.PrivateKey,
        localEphemeral: Curve25519.KeyAgreement.PrivateKey,
        remoteStatic: Data,
        remoteEphemeral: Data
    ) throws -> SecureChannel {
        let remoteStaticKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remoteStatic)
        let remoteEphemeralKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remoteEphemeral)

        // ee, es (initiator ephemeral × responder static), se (initiator static × responder ephemeral)
        let ee = try localEphemeral.sharedSecretFromKeyAgreement(with: remoteEphemeralKey)
        let es, se: SharedSecret
        if isInitiator {
            es = try localEphemeral.sharedSecretFromKeyAgreement(with: remoteStaticKey)
            se = try localStatic.sharedSecretFromKeyAgreement(with: remoteEphemeralKey)
        } else {
            es = try localStatic.sharedSecretFromKeyAgreement(with: remoteEphemeralKey)
            se = try localEphemeral.sharedSecretFromKeyAgreement(with: remoteStaticKey)
        }
        var material = Data()
        for secret in [ee, es, se] {
            secret.withUnsafeBytes { material.append(contentsOf: $0) }
        }

        let localKeys = localStatic.publicKey.rawRepresentation + localEphemeral.publicKey.rawRepresentation
        let remoteKeys = remoteStatic + remoteEphemeral
        let transcript = Data("ToggleMouse-session-v1".utf8)
            + (isInitiator ? localKeys + remoteKeys : remoteKeys + localKeys)

        let output = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: material),
            salt: Data(SHA256.hash(data: transcript)),
            info: Data("ToggleMouse-keys".utf8),
            outputByteCount: 32 * 3 + datagramIDSize
        )
        let bytes = output.withUnsafeBytes { Data($0) }
        let initiatorToResponder = SymmetricKey(data: bytes.subdata(in: 0..<32))
        let responderToInitiator = SymmetricKey(data: bytes.subdata(in: 32..<64))
        let datagramKey = SymmetricKey(data: bytes.subdata(in: 64..<96))
        let datagramID = bytes.subdata(in: 96..<bytes.count)
        return isInitiator
            ? SecureChannel(sendKey: initiatorToResponder, receiveKey: responderToInitiator, datagramKey: datagramKey, datagramID: datagramID)
            : SecureChannel(sendKey: responderToInitiator, receiveKey: initiatorToResponder, datagramKey: datagramKey, datagramID: datagramID)
    }
}
