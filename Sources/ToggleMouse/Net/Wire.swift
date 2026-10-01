import Foundation

/// Plaintext messages exchanged before a secure channel exists: pairing and the session handshake.
/// None of these carry secrets; authenticity comes from the pairing code check and the handshake keys.
enum ControlMessage: Codable, Equatable {
    case pairRequest(deviceID: String, name: String, commitment: Data)
    case pairResponse(deviceID: String, name: String, publicKey: Data, nonce: Data)
    case pairReveal(publicKey: Data, nonce: Data)
    case pairConfirm(accepted: Bool)
    case sessionHello(deviceID: String, name: String, staticKey: Data, ephemeralKey: Data)
    case sessionAccept(deviceID: String, staticKey: Data, ephemeralKey: Data)
    case rejected(reason: String)

    func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    static func decode(_ data: Data) -> ControlMessage? {
        try? JSONDecoder().decode(ControlMessage.self, from: data)
    }
}

/// Messages carried over the encrypted channel. Binary-encoded because mouse movement
/// is sent at the device's report rate.
enum StreamMessage: Equatable {
    case ready
    case heartbeat
    /// Emitter started streaming to this receiver.
    case begin
    /// Emitter stopped streaming; receiver releases anything still held.
    case end
    case mouseMove(dx: Float, dy: Float)
    case mouseButton(button: UInt8, down: Bool, clickState: UInt8)
    case scroll(continuous: Bool, lineX: Int32, lineY: Int32, pixelX: Float, pixelY: Float)
    case key(keyCode: UInt16, down: Bool, isRepeat: Bool, flags: UInt64)
    case flagsChanged(keyCode: UInt16, flags: UInt64)
}

extension StreamMessage {
    func encoded() -> Data {
        var w = ByteWriter()
        switch self {
        case .ready:
            w.u8(0x01)
        case .heartbeat:
            w.u8(0x02)
        case .begin:
            w.u8(0x03)
        case .end:
            w.u8(0x04)
        case let .mouseMove(dx, dy):
            w.u8(0x10); w.f32(dx); w.f32(dy)
        case let .mouseButton(button, down, clickState):
            w.u8(0x11); w.u8(button); w.bool(down); w.u8(clickState)
        case let .scroll(continuous, lineX, lineY, pixelX, pixelY):
            w.u8(0x12); w.bool(continuous); w.i32(lineX); w.i32(lineY); w.f32(pixelX); w.f32(pixelY)
        case let .key(keyCode, down, isRepeat, flags):
            w.u8(0x20); w.u16(keyCode); w.bool(down); w.bool(isRepeat); w.u64(flags)
        case let .flagsChanged(keyCode, flags):
            w.u8(0x21); w.u16(keyCode); w.u64(flags)
        }
        return w.data
    }

    init?(decoding data: Data) {
        var r = ByteReader(data)
        guard let tag = r.u8() else { return nil }
        switch tag {
        case 0x01:
            self = .ready
        case 0x02:
            self = .heartbeat
        case 0x03:
            self = .begin
        case 0x04:
            self = .end
        case 0x10:
            guard let dx = r.f32(), let dy = r.f32() else { return nil }
            self = .mouseMove(dx: dx, dy: dy)
        case 0x11:
            guard let button = r.u8(), let down = r.bool(), let clickState = r.u8() else { return nil }
            self = .mouseButton(button: button, down: down, clickState: clickState)
        case 0x12:
            guard let continuous = r.bool(), let lineX = r.i32(), let lineY = r.i32(),
                  let pixelX = r.f32(), let pixelY = r.f32() else { return nil }
            self = .scroll(continuous: continuous, lineX: lineX, lineY: lineY, pixelX: pixelX, pixelY: pixelY)
        case 0x20:
            guard let keyCode = r.u16(), let down = r.bool(), let isRepeat = r.bool(), let flags = r.u64() else { return nil }
            self = .key(keyCode: keyCode, down: down, isRepeat: isRepeat, flags: flags)
        case 0x21:
            guard let keyCode = r.u16(), let flags = r.u64() else { return nil }
            self = .flagsChanged(keyCode: keyCode, flags: flags)
        default:
            return nil
        }
        guard r.isAtEnd else { return nil }
    }
}

/// Big-endian binary writer.
struct ByteWriter {
    private(set) var data = Data()

    mutating func u8(_ value: UInt8) { data.append(value) }
    mutating func bool(_ value: Bool) { u8(value ? 1 : 0) }
    mutating func u16(_ value: UInt16) { append(value) }
    mutating func u32(_ value: UInt32) { append(value) }
    mutating func u64(_ value: UInt64) { append(value) }
    mutating func i32(_ value: Int32) { u32(UInt32(bitPattern: value)) }
    mutating func f32(_ value: Float) { u32(value.bitPattern) }

    private mutating func append<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }
}

/// Big-endian binary reader; every read returns nil once the input is exhausted.
struct ByteReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ data: Data) { bytes = [UInt8](data) }

    var isAtEnd: Bool { offset == bytes.count }

    mutating func u8() -> UInt8? { read(UInt8.self) }
    mutating func u16() -> UInt16? { read(UInt16.self) }
    mutating func u32() -> UInt32? { read(UInt32.self) }
    mutating func u64() -> UInt64? { read(UInt64.self) }
    mutating func i32() -> Int32? { u32().map { Int32(bitPattern: $0) } }
    mutating func f32() -> Float? { u32().map { Float(bitPattern: $0) } }

    mutating func bool() -> Bool? {
        switch u8() {
        case 0: return false
        case 1: return true
        default: return nil
        }
    }

    private mutating func read<T: FixedWidthInteger & UnsignedInteger>(_: T.Type) -> T? {
        let size = MemoryLayout<T>.size
        guard offset + size <= bytes.count else { return nil }
        var value: T = 0
        for byte in bytes[offset..<offset + size] {
            value = value << 8 | T(byte)
        }
        offset += size
        return value
    }
}
