import CoreGraphics
import Foundation

/// Replays streamed input as local events. Requires Accessibility permission.
/// Tracks what is held so everything can be released when a stream ends or drops.
///
/// All work runs on a dedicated high-priority queue, so a busy main thread doesn't
/// delay input. Calls are queued in order.
final class EventInjector {
    private static let smoothingInterval: DispatchTimeInterval = .milliseconds(2)

    private let queue = DispatchQueue(label: "app.togglemouse.injector", qos: .userInteractive)
    private var smoother = PointerSmoother()
    private var smoothingTimer: DispatchSourceTimer?
    private let source = CGEventSource(stateID: .hidSystemState)
    private var pressedButtons: Set<UInt8> = []
    private var pressedKeys: Set<UInt16> = []
    private var flags: CGEventFlags = []
    /// Where we last put the cursor. The system position lags behind posted events,
    /// so reading it back on every move drops deltas and makes the cursor stutter.
    private var location: CGPoint?
    private var lastMove = Date.distantPast
    private var displays: [CGRect] = []
    private var displaysRefreshed = Date.distantPast

    /// Modifier flag → left-hand key code, used to release stuck modifiers.
    private static let modifierKeys: [(CGEventFlags, UInt16)] = [
        (.maskCommand, 0x37), (.maskShift, 0x38), (.maskAlternate, 0x3A), (.maskControl, 0x3B), (.maskSecondaryFn, 0x3F),
    ]

    init() {
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.smoothingInterval, leeway: .nanoseconds(0))
        timer.setEventHandler { [weak self] in self?.smoothingTick() }
        smoothingTimer = timer
    }

    deinit {
        // A suspended dispatch source must be resumed before it can be released.
        if smoother.isIdle { smoothingTimer?.resume() }
        smoothingTimer?.cancel()
    }

    func apply(_ message: StreamMessage) {
        queue.async { self.perform(message) }
    }

    func releaseAll() {
        queue.async { self.releaseAllNow() }
    }

    /// Starts smoothing a new stream whose pointer total is currently (x, y).
    func beginPointer(x: Double, y: Double) {
        queue.async { self.stopSmoothing(resetTo: (x, y)) }
    }

    /// Queues a pointer total for smoothed playback. Times are uptime nanoseconds.
    func pointer(x: Double, y: Double, sentAt: Int64, arrivedAt: Int64, viaDatagram: Bool) {
        queue.async {
            let wasIdle = self.smoother.isIdle
            self.smoother.add(x: x, y: y, sentAt: sentAt, arrivedAt: arrivedAt, viaDatagram: viaDatagram)
            if wasIdle { self.smoothingTimer?.resume() }
        }
    }

    private func smoothingTick() {
        let previous = (x: smoother.postedX, y: smoother.postedY)
        if let target = smoother.target(at: Int64(DispatchTime.now().uptimeNanoseconds)) {
            movePointer(dx: target.x - previous.x, dy: target.y - previous.y)
        }
        if smoother.isIdle { smoothingTimer?.suspend() }
    }

    /// Applies any buffered movement at once, so the next click lands where the cursor should be.
    private func flushPointer() {
        guard !smoother.isIdle else { return }
        let previous = (x: smoother.postedX, y: smoother.postedY)
        let target = smoother.flush()
        smoothingTimer?.suspend()
        movePointer(dx: target.x - previous.x, dy: target.y - previous.y)
    }

    private func stopSmoothing(resetTo position: (x: Double, y: Double)) {
        if !smoother.isIdle { smoothingTimer?.suspend() }
        smoother.reset(x: position.x, y: position.y)
    }

    private func perform(_ message: StreamMessage) {
        if message.dependsOnPointer { flushPointer() }
        switch message {
        case let .mouseMove(dx, dy):
            moveMouse(dx: CGFloat(dx), dy: CGFloat(dy))
        case let .mouseButton(button, down, clickState):
            pressMouse(button: button, down: down, clickState: clickState)
        case let .scroll(continuous, lineX, lineY, pixelX, pixelY):
            scroll(continuous: continuous, lineX: lineX, lineY: lineY, pixelX: pixelX, pixelY: pixelY)
        case let .key(keyCode, down, isRepeat, flags):
            pressKey(keyCode: keyCode, down: down, isRepeat: isRepeat, flags: CGEventFlags(rawValue: flags))
        case let .flagsChanged(keyCode, flags):
            changeFlags(keyCode: keyCode, flags: CGEventFlags(rawValue: flags))
        case .ready, .heartbeat, .begin, .end, .pointer:
            break
        }
    }

    private func releaseAllNow() {
        stopSmoothing(resetTo: (smoother.postedX, smoother.postedY))
        for keyCode in pressedKeys {
            pressKey(keyCode: keyCode, down: false, isRepeat: false, flags: flags)
        }
        for button in pressedButtons {
            pressMouse(button: button, down: false, clickState: 1)
        }
        for (flag, keyCode) in Self.modifierKeys where flags.contains(flag) {
            changeFlags(keyCode: keyCode, flags: flags.subtracting(flag))
        }
        pressedKeys = []
        pressedButtons = []
        flags = []
        location = nil
    }

    // MARK: Mouse

    /// Our tracked position while moves keep coming; after a pause, re-read the system
    /// position in case the receiver's own mouse moved the cursor.
    private var cursorLocation: CGPoint {
        if let location, Date().timeIntervalSince(lastMove) < 0.5 { return location }
        let current = CGEvent(source: nil)?.location ?? .zero
        location = current
        return current
    }

    private func movePointer(dx: Double, dy: Double) {
        guard dx != 0 || dy != 0 else { return }
        moveMouse(dx: CGFloat(dx), dy: CGFloat(dy))
    }

    private func moveMouse(dx: CGFloat, dy: CGFloat) {
        let current = cursorLocation
        let target = clampToDisplays(CGPoint(x: current.x + dx, y: current.y + dy), from: current)
        location = target
        lastMove = Date()
        let (type, button): (CGEventType, CGMouseButton) =
            if pressedButtons.contains(0) { (.leftMouseDragged, .left) }
            else if pressedButtons.contains(1) { (.rightMouseDragged, .right) }
            else if let other = pressedButtons.min() { (.otherMouseDragged, CGMouseButton(rawValue: UInt32(other)) ?? .center) }
            else { (.mouseMoved, .left) }
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: target, mouseButton: button) else { return }
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    private func pressMouse(button: UInt8, down: Bool, clickState: UInt8) {
        let type: CGEventType = switch (button, down) {
        case (0, true): .leftMouseDown
        case (0, false): .leftMouseUp
        case (1, true): .rightMouseDown
        case (1, false): .rightMouseUp
        case (_, true): .otherMouseDown
        case (_, false): .otherMouseUp
        }
        let mouseButton = CGMouseButton(rawValue: UInt32(button)) ?? .center
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: cursorLocation, mouseButton: mouseButton) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(max(clickState, 1)))
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        event.flags = flags
        event.post(tap: .cghidEventTap)
        if down { pressedButtons.insert(button) } else { pressedButtons.remove(button) }
    }

    private func scroll(continuous: Bool, lineX: Int32, lineY: Int32, pixelX: Float, pixelY: Float) {
        let event: CGEvent? = continuous
            ? CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: Int32(pixelY), wheel2: Int32(pixelX), wheel3: 0)
            : CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2, wheel1: lineY, wheel2: lineX, wheel3: 0)
        guard let event else { return }
        // Carry the emitter's accelerated point deltas, which most apps read.
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: Double(pixelY))
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: Double(pixelX))
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    /// Keeps the cursor on screen: if the target falls between displays, clamp it to
    /// the display the cursor is currently on.
    private func clampToDisplays(_ point: CGPoint, from current: CGPoint) -> CGPoint {
        if Date().timeIntervalSince(displaysRefreshed) > 2 {
            displays = Self.activeDisplayBounds()
            displaysRefreshed = Date()
        }
        if displays.contains(where: { $0.contains(point) }) { return point }
        guard let display = displays.first(where: { $0.contains(current) }) ?? displays.first else { return point }
        return CGPoint(
            x: min(max(point.x, display.minX), display.maxX - 1),
            y: min(max(point.y, display.minY), display.maxY - 1)
        )
    }

    private static func activeDisplayBounds() -> [CGRect] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    // MARK: Keyboard

    private func pressKey(keyCode: UInt16, down: Bool, isRepeat: Bool, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { return }
        event.flags = flags
        event.setIntegerValueField(.keyboardEventAutorepeat, value: isRepeat ? 1 : 0)
        event.post(tap: .cghidEventTap)
        if down { pressedKeys.insert(keyCode) } else { pressedKeys.remove(keyCode) }
    }

    private func changeFlags(keyCode: UInt16, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) else { return }
        event.type = .flagsChanged
        event.flags = flags
        event.post(tap: .cghidEventTap)
        self.flags = flags
    }
}
