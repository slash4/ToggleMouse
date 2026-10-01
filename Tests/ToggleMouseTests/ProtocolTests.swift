import CoreGraphics
import CryptoKit
import XCTest
@testable import ToggleMouse

final class WireTests: XCTestCase {
    func testStreamMessagesRoundTrip() {
        let messages: [StreamMessage] = [
            .ready, .heartbeat, .begin, .end,
            .placement(side: .right, entry: 0.25), .placement(side: nil, entry: nil), .placement(side: .top, entry: nil),
            .edgeExit(position: 0.75),
            .mouseMove(dx: -3.5, dy: 12),
            .pointer(sequence: 42, x: -1234.5, y: 0.25, time: 123_456_789_012),
            .mouseButton(button: 2, down: true, clickState: 2),
            .scroll(continuous: true, lineX: -1, lineY: 3, pixelX: -4.25, pixelY: 30),
            .key(keyCode: 0x7E, down: false, isRepeat: true, flags: CGEventFlags.maskCommand.rawValue),
            .flagsChanged(keyCode: 0x38, flags: CGEventFlags.maskShift.rawValue),
        ]
        for message in messages {
            XCTAssertEqual(StreamMessage(decoding: message.encoded()), message)
        }
    }

    func testRejectsTruncatedAndTrailingData() {
        let encoded = StreamMessage.mouseMove(dx: 1, dy: 2).encoded()
        XCTAssertNil(StreamMessage(decoding: encoded.dropLast()))
        XCTAssertNil(StreamMessage(decoding: encoded + Data([0])))
        XCTAssertNil(StreamMessage(decoding: Data([0xFF])))
    }

    func testControlMessageRoundTrip() {
        let message = ControlMessage.sessionHello(deviceID: "id", name: "Mac", staticKey: Data([1, 2]), ephemeralKey: Data([3]))
        XCTAssertEqual(ControlMessage.decode(message.encoded()), message)
    }

    func testAddressParsing() {
        XCTAssertEqual(NetworkConfig.endpoint(forAddress: " 192.168.1.20 "), .hostPort(host: "192.168.1.20", port: 52525))
        XCTAssertEqual(NetworkConfig.endpoint(forAddress: "mac.local:6000"), .hostPort(host: "mac.local", port: 6000))
        XCTAssertNil(NetworkConfig.endpoint(forAddress: "mac.local:abc"))
        XCTAssertNil(NetworkConfig.endpoint(forAddress: ""))
    }
}

final class CryptoTests: XCTestCase {
    private func makeChannels(responderStatic: Curve25519.KeyAgreement.PrivateKey? = nil) throws -> (SecureChannel, SecureChannel) {
        let initiatorStatic = Curve25519.KeyAgreement.PrivateKey()
        let realResponderStatic = Curve25519.KeyAgreement.PrivateKey()
        let initiatorEphemeral = Curve25519.KeyAgreement.PrivateKey()
        let responderEphemeral = Curve25519.KeyAgreement.PrivateKey()
        let initiator = try SecureChannel.establish(
            isInitiator: true,
            localStatic: initiatorStatic,
            localEphemeral: initiatorEphemeral,
            remoteStatic: realResponderStatic.publicKey.rawRepresentation,
            remoteEphemeral: responderEphemeral.publicKey.rawRepresentation
        )
        let responder = try SecureChannel.establish(
            isInitiator: false,
            localStatic: responderStatic ?? realResponderStatic,
            localEphemeral: responderEphemeral,
            remoteStatic: initiatorStatic.publicKey.rawRepresentation,
            remoteEphemeral: initiatorEphemeral.publicKey.rawRepresentation
        )
        return (initiator, responder)
    }

    func testHandshakeDerivesMatchingKeys() throws {
        let (initiator, responder) = try makeChannels()
        XCTAssertEqual(try responder.open(initiator.seal(.ready)), .ready)
        XCTAssertEqual(try initiator.open(responder.seal(.heartbeat)), .heartbeat)
        XCTAssertEqual(try responder.open(initiator.seal(.mouseMove(dx: 1, dy: 1))), .mouseMove(dx: 1, dy: 1))
    }

    func testImpostorWithoutPairedKeyCannotDecrypt() throws {
        let (initiator, impostor) = try makeChannels(responderStatic: Curve25519.KeyAgreement.PrivateKey())
        XCTAssertThrowsError(try impostor.open(initiator.seal(.ready)))
    }

    func testRejectsReplayAndTampering() throws {
        let (initiator, responder) = try makeChannels()
        let first = try initiator.seal(.begin)
        XCTAssertEqual(try responder.open(first), .begin)
        XCTAssertThrowsError(try responder.open(first), "replayed frame must fail")

        var tampered = try initiator.seal(.end)
        tampered[0] ^= 1
        XCTAssertThrowsError(try responder.open(tampered))
    }

    func testDatagramsRoundTripAndRejectStaleOrForeign() throws {
        let (emitter, receiver) = try makeChannels()
        XCTAssertEqual(emitter.datagramID, receiver.datagramID)

        let first = try emitter.sealDatagram(.pointer(sequence: 1, x: 1, y: 2, time: 1), sequence: 1)
        let third = try emitter.sealDatagram(.pointer(sequence: 3, x: 5, y: 6, time: 3), sequence: 3)
        XCTAssertEqual(SecureChannel.datagramID(of: third), receiver.datagramID)
        XCTAssertEqual(try receiver.openDatagram(third), .pointer(sequence: 3, x: 5, y: 6, time: 3))
        XCTAssertThrowsError(try receiver.openDatagram(first), "older datagram must be dropped")
        XCTAssertThrowsError(try receiver.openDatagram(third), "replayed datagram must be dropped")

        var tampered = try emitter.sealDatagram(.pointer(sequence: 4, x: 0, y: 0, time: 4), sequence: 4)
        tampered[tampered.count - 1] ^= 1
        XCTAssertThrowsError(try receiver.openDatagram(tampered))

        let (other, _) = try makeChannels()
        XCTAssertThrowsError(try receiver.openDatagram(other.sealDatagram(.pointer(sequence: 9, x: 0, y: 0, time: 9), sequence: 9)))

        // Stream traffic is unaffected by the datagram path.
        XCTAssertEqual(try receiver.open(emitter.seal(.begin)), .begin)
    }

    func testPairingCodeIsSymmetricAndSixDigits() {
        let a = randomBytes(32), b = randomBytes(32), na = randomBytes(32), nb = randomBytes(32)
        let code = PairingCrypto.verificationCode(initiatorKey: a, responderKey: b, initiatorNonce: na, responderNonce: nb)
        XCTAssertEqual(code.count, 6)
        XCTAssertEqual(code, PairingCrypto.verificationCode(initiatorKey: a, responderKey: b, initiatorNonce: na, responderNonce: nb))
        XCTAssertNotEqual(PairingCrypto.commitment(publicKey: a, nonce: na), PairingCrypto.commitment(publicKey: a, nonce: nb))
    }
}

final class HotkeyTests: XCTestCase {
    func testMatchesIgnoringNonModifierFlags() {
        let hotkey = Hotkey(keyCode: 18, modifiers: CGEventFlags([.maskControl, .maskAlternate, .maskCommand]).rawValue)
        XCTAssertTrue(hotkey.matches(keyCode: 18, flags: [.maskControl, .maskAlternate, .maskCommand, .maskNonCoalesced]))
        XCTAssertFalse(hotkey.matches(keyCode: 18, flags: [.maskControl, .maskCommand]))
        XCTAssertFalse(hotkey.matches(keyCode: 18, flags: [.maskControl, .maskAlternate, .maskCommand, .maskShift]))
        XCTAssertEqual(hotkey.displayString, "⌃⌥⌘1")
    }

    func testDefaultHotkeySkipsUsed() {
        let first = Hotkey.defaultHotkey(excluding: [])!
        XCTAssertEqual(first.keyCode, 18)
        XCTAssertEqual(Hotkey.defaultHotkey(excluding: [first])?.keyCode, 19)
    }
}
