import XCTest
@testable import ToggleMouse

final class MediaKeyTests: XCTestCase {
    func testRebuiltEventDecodesToSameKey() throws {
        for (keyType, down, isRepeat) in [(UInt8(16), true, false), (0, false, false), (1, true, true), (7, false, false)] {
            let event = try XCTUnwrap(MediaKey.makeEvent(keyType: keyType, down: down, isRepeat: isRepeat))
            XCTAssertEqual(event.type.rawValue, MediaKey.systemDefinedType)
            let decoded = try XCTUnwrap(MediaKey.decode(event))
            XCTAssertEqual(decoded.keyType, keyType)
            XCTAssertEqual(decoded.down, down)
            XCTAssertEqual(decoded.isRepeat, isRepeat)
            XCTAssertEqual(StreamMessage(event: event, type: event.type), .mediaKey(keyType: keyType, down: down, isRepeat: isRepeat))
        }
    }

    func testLocalOnlyKeysAreNotStreamed() throws {
        // Power (6) and Caps Lock (4) must keep working on the emitter.
        for keyType in [UInt8(4), 5, 6] {
            let event = try XCTUnwrap(MediaKey.makeEvent(keyType: keyType, down: true, isRepeat: false))
            XCTAssertNil(MediaKey.decode(event))
            XCTAssertNil(StreamMessage(event: event, type: event.type))
        }
    }
}
