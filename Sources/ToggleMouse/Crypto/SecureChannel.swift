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
final class SecureChannel {
    private static let tagSize = 16

    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0

    init(sendKey: SymmetricKey, receiveKey: SymmetricKey) {
        self.sendKey = sendKey
        self.receiveKey = receiveKey
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
            outputByteCount: 64
        )
        let bytes = output.withUnsafeBytes { Data($0) }
        let initiatorToResponder = SymmetricKey(data: bytes.prefix(32))
        let responderToInitiator = SymmetricKey(data: bytes.suffix(32))
        return isInitiator
            ? SecureChannel(sendKey: initiatorToResponder, receiveKey: responderToInitiator)
            : SecureChannel(sendKey: responderToInitiator, receiveKey: initiatorToResponder)
    }
}
