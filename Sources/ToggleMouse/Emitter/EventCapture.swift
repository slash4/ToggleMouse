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
        let mask = Self.eventTypes.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
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

extension StreamMessage {
    /// Converts a captured event into its wire form; nil for types that aren't streamed.
    init?(event: CGEvent, type: CGEventType) {
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
