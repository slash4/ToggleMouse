import XCTest
@testable import ToggleMouse

final class PointerSmootherTests: XCTestCase {
    private let ms: Int64 = 1_000_000

    /// Moves 1 px per ms, captured every 8 ms, delivered in bursts every 32 ms.
    /// The emitter clock runs 10 s ahead of the receiver's.
    private func simulate(duration: Int64, onTick: (Int64, PointerSmoother, (x: Double, y: Double)?) -> Void) -> PointerSmoother {
        let clockOffset: Int64 = 10_000 * ms
        let burst: Int64 = 32 * ms
        let latency: Int64 = 5 * ms
        var captures: [(capture: Int64, arrival: Int64)] = []
        for capture in stride(from: Int64(0), to: duration, by: Int(8 * ms)) {
            let arrival: Int64 = ((capture + latency) / burst + 1) * burst
            captures.append((capture, arrival))
        }
        var smoother = PointerSmoother()
        var next = 0
        for now in stride(from: Int64(0), to: duration + 100 * ms, by: Int(2 * ms)) {
            while next < captures.count, captures[next].arrival <= now {
                let sample = captures[next]
                let total = Double(sample.capture / ms)
                smoother.add(x: total, y: -total, sentAt: sample.capture + clockOffset, arrivedAt: sample.arrival, viaDatagram: true)
                next += 1
            }
            let target = smoother.target(at: now)
            onTick(now, smoother, target)
        }
        return smoother
    }

    func testBurstyArrivalPlaysBackSteadily() {
        var previous: Double?
        var steps: [Double] = []
        let smoother = simulate(duration: 3000 * ms) { now, smoother, target in
            guard let target else { return }
            if now > 1000 * ms, now < 2900 * ms, let previous { steps.append(target.x - previous) }
            previous = target.x
        }
        XCTAssertFalse(steps.isEmpty)
        // 2 ms ticks at 1 px/ms: every step should be close to 2 px, with no pauses or jumps.
        XCTAssertGreaterThan(steps.min()!, 1.5, "cursor paused")
        XCTAssertLessThan(steps.max()!, 2.5, "cursor jumped")
        XCTAssertLessThanOrEqual(smoother.delay, 40 * ms)
        XCTAssertGreaterThan(smoother.delay, 20 * ms, "buffer should grow to cover 32 ms bursts")
    }

    func testEndsExactlyOnLatestTotal() {
        let smoother = simulate(duration: 500 * ms) { _, _, _ in }
        XCTAssertTrue(smoother.isIdle)
        XCTAssertEqual(smoother.postedX, 496)
        XCTAssertEqual(smoother.postedY, -496)
    }

    func testFlushJumpsToLatestAndReset() {
        var smoother = PointerSmoother()
        smoother.reset(x: 100, y: 100)
        smoother.add(x: 110, y: 90, sentAt: 0, arrivedAt: 5 * ms, viaDatagram: true)
        smoother.add(x: 120, y: 80, sentAt: 8 * ms, arrivedAt: 13 * ms, viaDatagram: true)
        XCTAssertFalse(smoother.isIdle)
        let flushed = smoother.flush()
        XCTAssertEqual(flushed.x, 120)
        XCTAssertEqual(flushed.y, 80)
        XCTAssertTrue(smoother.isIdle)
        XCTAssertNil(smoother.target(at: 50 * ms))
    }
}
