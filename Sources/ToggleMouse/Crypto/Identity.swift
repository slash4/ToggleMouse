import CryptoKit
import Foundation
import Security

/// This Mac's long-term identity: a random device ID and a Curve25519 key pair,
/// persisted in the login Keychain. The public key is what peers pin when pairing.
final class Identity {
    let deviceID: String
    let name: String
    let privateKey: Curve25519.KeyAgreement.PrivateKey

    var publicKey: Data { privateKey.publicKey.rawRepresentation }

    init(deviceID: String, name: String, privateKey: Curve25519.KeyAgreement.PrivateKey) {
        self.deviceID = deviceID
        self.name = name
        self.privateKey = privateKey
    }

    private struct Stored: Codable {
        var deviceID: String
        var privateKey: Data
    }

    private static let service = "app.togglemouse.identity"
    private static let account = "identity"

    static func loadOrCreate() throws -> Identity {
        let name = Host.current().localizedName ?? "Mac"
        if let data = try readKeychain() {
            let stored = try JSONDecoder().decode(Stored.self, from: data)
            let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: stored.privateKey)
            return Identity(deviceID: stored.deviceID, name: name, privateKey: key)
        }
        let identity = Identity(deviceID: UUID().uuidString, name: name, privateKey: .init())
        let stored = Stored(deviceID: identity.deviceID, privateKey: identity.privateKey.rawRepresentation)
        try writeKeychain(JSONEncoder().encode(stored))
        return identity
    }

    private static func readKeychain() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError(status: status) }
        return data
    }

    private static func writeKeychain(_ data: Data) throws {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "ToggleMouse device identity",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        return "Keychain error \(status): \(message)"
    }
}

func randomBytes(_ count: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
    precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
    return Data(bytes)
}
