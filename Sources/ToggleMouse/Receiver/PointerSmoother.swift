import Foundation

/// Jitter buffer for pointer movement.
///
/// Wi-Fi and thread scheduling deliver pointer updates in bursts, so applying each one on
/// arrival makes the cursor jump and then pause. Instead, each update is scheduled at its
/// capture time on the emitter, plus the fastest delay seen recently, plus a small buffer
/// sized to cover most of the variation and one gap between samples (the next sample must
/// be on hand to interpolate toward). `target(at:)` then gives the cursor position along
/// the interpolated path, sampled on a steady timer.
///
/// All times are uptime nanoseconds; emitter and receiver clocks differ, but only the
/// difference between them matters and it is measured, not assumed.
struct PointerSmoother {
    static let minDelay: Int64 = 2_000_000
    static let maxDelay: Int64 = 40_000_000
    static let initialDelay: Int64 = 8_000_000
    /// Margin added on top of the measured variation.
    private static let delayMargin: Int64 = 1_000_000
    /// The lowest delay is tracked over two rolling windows of this length, so the estimate
    /// follows clock drift without forgetting the minimum all at once.
    private static let windowLength: Int64 = 1_000_000_000
    private static let excessHistory = 128
    private static let recomputeEvery = 32
    /// Stream copies only feed the estimate when datagrams have stopped (UDP blocked).
    private static let datagramGrace: Int64 = 1_000_000_000
    /// Gaps longer than this are pauses in movement, not the mouse's report interval.
    private static let maxSampleInterval: Int64 = 30_000_000

    private struct Sample {
        var time: Int64
        var x: Double
        var y: Double
    }

    private(set) var delay = initialDelay
    /// Position already applied to the cursor, as a running total.
    private(set) var postedX = 0.0
    private(set) var postedY = 0.0

    private var samples: [Sample] = []
    private var latestX = 0.0
    private var latestY = 0.0
    private var anchorTime: Int64 = 0

    private var windowMin = Int64.max
    private var previousWindowMin = Int64.max
    private var windowStart: Int64 = 0
    private var excess: [Int64] = []
    private var excessIndex = 0
    private var samplesSinceRecompute = 0
    private var lastDatagram = Int64.min
    private var lastSentAt: Int64?
    /// Smoothed time between captured samples, i.e. the mouse's report interval.
    private var sampleInterval: Int64 = 0

    var isIdle: Bool { samples.isEmpty }

    /// Starts a new stream from the given total, forgetting previous timing.
    mutating func reset(x: Double, y: Double) {
        self = PointerSmoother()
        postedX = x
        postedY = y
        latestX = x
        latestY = y
    }

    mutating func add(x: Double, y: Double, sentAt: Int64, arrivedAt: Int64, viaDatagram: Bool) {
        latestX = x
        latestY = y
        if samples.isEmpty { anchorTime = arrivedAt }

        if let lastSentAt {
            let gap = sentAt &- lastSentAt
            if gap > 0, gap <= Self.maxSampleInterval {
                sampleInterval = sampleInterval == 0 ? gap : (sampleInterval * 7 + gap) / 8
            }
        }
        lastSentAt = sentAt

        let offset = arrivedAt &- sentAt
        if viaDatagram { lastDatagram = arrivedAt }
        if viaDatagram || arrivedAt &- lastDatagram > Self.datagramGrace {
            updateEstimate(offset: offset, now: arrivedAt)
        }
        let base = min(windowMin, previousWindowMin)
        let playAt = sentAt &+ (base == .max ? offset : base) &+ delay
        samples.append(Sample(time: max(playAt, samples.last?.time ?? .min), x: x, y: y))
    }

    /// Where the cursor should be at `now`. Returns nil when nothing is pending.
    mutating func target(at now: Int64) -> (x: Double, y: Double)? {
        while samples.count >= 2, samples[1].time <= now {
            samples.removeFirst()
        }
        guard let first = samples.first else { return nil }

        let target: (x: Double, y: Double)
        if first.time > now {
            // Glide from where the cursor is toward the next sample.
            let span = Double(first.time - anchorTime)
            let t = span > 0 ? Double(now - anchorTime) / span : 1
            target = (postedX + (first.x - postedX) * t, postedY + (first.y - postedY) * t)
        } else if samples.count >= 2, samples[1].time > first.time {
            let next = samples[1]
            let t = Double(now - first.time) / Double(next.time - first.time)
            target = (first.x + (next.x - first.x) * t, first.y + (next.y - first.y) * t)
        } else {
            target = (first.x, first.y)
            samples.removeAll()
        }
        anchorTime = now
        postedX = target.x
        postedY = target.y
        return target
    }

    /// Jumps straight to the latest position, for clicks and scrolls that must land there.
    mutating func flush() -> (x: Double, y: Double) {
        samples.removeAll()
        postedX = latestX
        postedY = latestY
        return (latestX, latestY)
    }

    private mutating func updateEstimate(offset: Int64, now: Int64) {
        if now &- windowStart > Self.windowLength {
            previousWindowMin = windowMin
            windowMin = .max
            windowStart = now
        }
        windowMin = min(windowMin, offset)
        let excessValue = max(0, offset &- min(windowMin, previousWindowMin))

        if excess.count < Self.excessHistory {
            excess.append(excessValue)
        } else {
            excess[excessIndex] = excessValue
            excessIndex = (excessIndex + 1) % Self.excessHistory
        }
        samplesSinceRecompute += 1
        guard samplesSinceRecompute >= Self.recomputeEvery else { return }
        samplesSinceRecompute = 0

        let sorted = excess.sorted()
        let p95 = sorted[min(sorted.count - 1, sorted.count * 95 / 100)]
        let wanted = min(max(p95 + sampleInterval + Self.delayMargin, Self.minDelay), Self.maxDelay)
        // Grow at once to stop stutter; shrink gently so the cursor doesn't lurch forward.
        delay = wanted > delay ? wanted : (delay * 7 + wanted) / 8
    }
}
