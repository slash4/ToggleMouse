import AppKit
import CoreGraphics
import Foundation

/// Active session-level event tap for mouse and keyboard input. Requires Accessibility
/// permission. The handler returns true to swallow an event.
final class EventCapture {
    var handler: ((CGEventType, CGEvent) -> Bool)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private static let eventTypes: [CGEventType] = [
        .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
        .scrollWheel, .keyDown, .keyUp, .flagsChanged,
    ]

    /// Returns false when the tap can't be created, usually for lack of Accessibility permission.
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = Self.eventTypes.reduce(CGEventMask(1) << MediaKey.systemDefinedType) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        runLoopSource = source
        return true
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        runLoopSource = nil
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // The system disables slow taps; turn it straight back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        return handler?(type, event) == true ? nil : Unmanaged.passUnretained(event)
    }
}

private func eventTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    return Unmanaged<EventCapture>.fromOpaque(userInfo).takeUnretainedValue().handle(type, event)
}

enum EventClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// When the event was captured, in uptime nanoseconds. Using the event's own timestamp
    /// rather than the time the tap ran keeps main-thread delays out of the timing.
    /// `CGEvent.timestamp` is documented as nanoseconds but is in mach ticks on Apple
    /// silicon, so take whichever reading is closer to the current time.
    static func uptimeNanoseconds(of event: CGEvent) -> UInt64 {
        let stamp = event.timestamp
        let now = DispatchTime.now().uptimeNanoseconds
        guard timebase.numer != timebase.denom else { return stamp }
        let converted = stamp &* UInt64(timebase.numer) / UInt64(timebase.denom)
        let distance = { (value: UInt64) in value > now ? value - now : now - value }
        return distance(stamp) < distance(converted) ? stamp : converted
    }
}

/// Media keys reach the event tap as NX_SYSDEFINED events (type 14) of subtype 8, with the
/// key and its state packed into data1. CGEventType has no case for them.
enum MediaKey {
    static let systemDefinedType: UInt32 = 14
    private static let auxControlSubtype: Int16 = 8
    private static let downState = 0xA
    private static let upState = 0xB

    /// NX_KEYTYPE values that are streamed: volume up/down (0, 1), brightness up/down (2, 3),
    /// mute (7), eject (14), play (16), next (17), previous (18), fast-forward (19),
    /// rewind (20) and keyboard backlight up/down (21, 22). Caps Lock, Help and Power stay local.
    static let streamedKeys: Set<UInt8> = [0, 1, 2, 3, 7, 14, 16, 17, 18, 19, 20, 21, 22]

    static func decode(_ event: CGEvent) -> (keyType: UInt8, down: Bool, isRepeat: Bool)? {
        guard let nsEvent = NSEvent(cgEvent: event), nsEvent.subtype.rawValue == auxControlSubtype else { return nil }
        let data1 = nsEvent.data1
        let keyType = (data1 >> 16) & 0xFFFF
        let state = (data1 >> 8) & 0xFF
        guard keyType < 256, streamedKeys.contains(UInt8(keyType)), state == downState || state == upState else { return nil }
        return (UInt8(keyType), state == downState, data1 & 1 != 0)
    }

    static func makeEvent(keyType: UInt8, down: Bool, isRepeat: Bool) -> CGEvent? {
        let flags = (down ? downState : upState) << 8 | (isRepeat ? 1 : 0)
        return NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags & 0xFF00)),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: auxControlSubtype,
            data1: Int(keyType) << 16 | flags,
            data2: -1
        )?.cgEvent
    }
}

extension StreamMessage {
    /// Clicks and scrolls act at the cursor, so the pointer must be synced before them.
    var dependsOnPointer: Bool {
        switch self {
        case .mouseButton, .scroll: return true
        default: return false
        }
    }

    /// Converts a captured event into its wire form; nil for types that aren't streamed.
    init?(event: CGEvent, type: CGEventType) {
        if type.rawValue == MediaKey.systemDefinedType {
            guard let key = MediaKey.decode(event) else { return nil }
            self = .mediaKey(keyType: key.keyType, down: key.down, isRepeat: key.isRepeat)
            return
        }
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            self = .mouseMove(
                dx: Float(event.getDoubleValueField(.mouseEventDeltaX)),
                dy: Float(event.getDoubleValueField(.mouseEventDeltaY))
            )
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp:
            self = .mouseButton(
                button: UInt8(clamping: event.getIntegerValueField(.mouseEventButtonNumber)),
                down: type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown,
                clickState: UInt8(clamping: event.getIntegerValueField(.mouseEventClickState))
            )
        case .scrollWheel:
            self = .scroll(
                continuous: event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
                lineX: Int32(clamping: event.getIntegerValueField(.scrollWheelEventDeltaAxis2)),
                lineY: Int32(clamping: event.getIntegerValueField(.scrollWheelEventDeltaAxis1)),
                pixelX: Float(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)),
                pixelY: Float(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1))
            )
        case .keyDown, .keyUp:
            self = .key(
                keyCode: UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode)),
                down: type == .keyDown,
                isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                flags: event.flags.rawValue
            )
        case .flagsChanged:
            self = .flagsChanged(
                keyCode: UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode)),
                flags: event.flags.rawValue
            )
        default:
            return nil
        }
    }
}
