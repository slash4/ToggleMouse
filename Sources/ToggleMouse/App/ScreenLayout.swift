import CoreGraphics
import Foundation

/// Where a receiver sits relative to the emitter's screens.
enum ScreenEdge: UInt8, Codable, CaseIterable, Identifiable {
    case left = 1, right, top, bottom

    var id: Self { self }

    var title: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        case .top: "Top"
        case .bottom: "Bottom"
        }
    }

    var opposite: ScreenEdge {
        switch self {
        case .left: .right
        case .right: .left
        case .top: .bottom
        case .bottom: .top
        }
    }

    var isHorizontal: Bool { self == .top || self == .bottom }

    /// The part of a movement that pushes through this edge.
    func outward(dx: Double, dy: Double) -> Double {
        switch self {
        case .left: -dx
        case .right: dx
        case .top: -dy
        case .bottom: dy
        }
    }
}

/// The arrangement of this Mac's displays, in global coordinates (origin top-left, y down).
struct ScreenLayout {
    let displays: [CGRect]

    static func current() -> ScreenLayout {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return ScreenLayout(displays: []) }
        return ScreenLayout(displays: ids.prefix(Int(count)).map { CGDisplayBounds($0) })
    }

    /// The display under the point, allowing for the cursor sitting on a display's far edge.
    func display(containing point: CGPoint) -> CGRect? {
        displays.first { $0.contains(point) } ?? displays.first { $0.insetBy(dx: -1, dy: -1).contains(point) }
    }

    /// Keeps a point on screen: if it falls between displays, clamp it to the display
    /// the cursor is coming from.
    func clamp(_ point: CGPoint, from current: CGPoint) -> CGPoint {
        if displays.contains(where: { $0.contains(point) }) { return point }
        guard let display = display(containing: current) ?? displays.first else { return point }
        return CGPoint(
            x: min(max(point.x, display.minX), display.maxX - 1),
            y: min(max(point.y, display.minY), display.maxY - 1)
        )
    }

    /// True when the point is against the given edge of its display and no other display
    /// continues beyond it, so the cursor can't go further that way.
    func isAtOuterEdge(_ point: CGPoint, _ edge: ScreenEdge) -> Bool {
        guard let display = display(containing: point) else { return false }
        let beyond: CGPoint
        switch edge {
        case .left:
            guard point.x <= display.minX + 1 else { return false }
            beyond = CGPoint(x: display.minX - 0.5, y: point.y)
        case .right:
            guard point.x >= display.maxX - 2 else { return false }
            beyond = CGPoint(x: display.maxX + 0.5, y: point.y)
        case .top:
            guard point.y <= display.minY + 1 else { return false }
            beyond = CGPoint(x: point.x, y: display.minY - 0.5)
        case .bottom:
            guard point.y >= display.maxY - 2 else { return false }
            beyond = CGPoint(x: point.x, y: display.maxY + 0.5)
        }
        return !displays.contains { $0.contains(beyond) }
    }

    /// Position along the edge as a fraction of the point's display (0 = top or left end).
    func fraction(of point: CGPoint, along edge: ScreenEdge) -> Double {
        guard let display = display(containing: point) else { return 0.5 }
        let value = edge.isHorizontal
            ? (point.x - display.minX) / display.width
            : (point.y - display.minY) / display.height
        return min(max(Double(value), 0), 1)
    }

    /// A point just inside the outermost displays on the given edge, at the given fraction
    /// of their combined span. Used to bring the cursor in where it left the other Mac.
    func entryPoint(on edge: ScreenEdge, fraction: Double) -> CGPoint? {
        let extreme: (CGRect) -> CGFloat = switch edge {
        case .left: { -$0.minX }
        case .right: { $0.maxX }
        case .top: { -$0.minY }
        case .bottom: { $0.maxY }
        }
        guard let outermost = displays.map(extreme).max() else { return nil }
        let candidates = displays.filter { extreme($0) == outermost }
        let start: (CGRect) -> CGFloat = edge.isHorizontal ? { $0.minX } : { $0.minY }
        let end: (CGRect) -> CGFloat = edge.isHorizontal ? { $0.maxX } : { $0.maxY }
        let spanStart = candidates.map(start).min()!
        let spanEnd = candidates.map(end).max()!
        let along = spanStart + CGFloat(min(max(fraction, 0), 1)) * (spanEnd - spanStart)

        // Displays on the edge may leave gaps; use the nearest one.
        let distance = { (rect: CGRect) in max(start(rect) - along, along - (end(rect) - 1), 0) }
        let display = candidates.min { distance($0) < distance($1) }!
        let clamped = min(max(along, start(display)), end(display) - 1)
        let inset: CGFloat = 2
        switch edge {
        case .left: return CGPoint(x: display.minX + inset, y: clamped)
        case .right: return CGPoint(x: display.maxX - 1 - inset, y: clamped)
        case .top: return CGPoint(x: clamped, y: display.minY + inset)
        case .bottom: return CGPoint(x: clamped, y: display.maxY - 1 - inset)
        }
    }
}

/// Requires a deliberate push against an edge before switching, so brushing past it
/// on the way to a corner or the Dock doesn't.
struct EdgePush {
    static let threshold = 30.0
    static let resetAfter: TimeInterval = 0.3

    private var edge: ScreenEdge?
    private var distance = 0.0
    private var lastPush: TimeInterval = 0

    /// `edge` is the edge the cursor is against, or nil when it isn't at one.
    /// Returns true when the push is far enough to switch.
    mutating func push(against edge: ScreenEdge?, dx: Double, dy: Double, now: TimeInterval) -> Bool {
        guard let edge else {
            reset()
            return false
        }
        let outward = edge.outward(dx: dx, dy: dy)
        if outward < 0 || edge != self.edge || now - lastPush > Self.resetAfter {
            reset()
        }
        guard outward > 0 else { return false }
        self.edge = edge
        distance += outward
        lastPush = now
        guard distance >= Self.threshold else { return false }
        reset()
        return true
    }

    mutating func reset() {
        edge = nil
        distance = 0
    }
}
