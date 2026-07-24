import Foundation

/// Sliding-window median filter over the most recent `windowSize` values.
/// Raw values are never modified; callers keep raw and filtered streams
/// separate.
struct MedianWindowFilter {
    let windowSize: Int
    private var buffer: [Double] = []

    init(windowSize: Int) {
        self.windowSize = max(1, windowSize)
    }

    /// Adds a value and returns the median of the current window.
    mutating func add(_ value: Double) -> Double {
        buffer.append(value)
        if buffer.count > windowSize {
            buffer.removeFirst(buffer.count - windowSize)
        }
        // Non-empty by construction.
        return Statistics.median(buffer) ?? value
    }

    mutating func reset() { buffer.removeAll() }

    var currentWindowCount: Int { buffer.count }
}

/// Exponential moving average: y_n = alpha * x_n + (1 - alpha) * y_{n-1}.
struct ExponentialMovingAverageFilter {
    let alpha: Double
    private var value: Double?

    init(alpha: Double) {
        self.alpha = max(0.0001, min(1.0, alpha))
    }

    mutating func add(_ newValue: Double) -> Double {
        if let v = value {
            let updated = alpha * newValue + (1 - alpha) * v
            value = updated
            return updated
        }
        value = newValue
        return newValue
    }

    mutating func reset() { value = nil }

    var current: Double? { value }
}

/// Combined filter chain for the TrueDepth surface distance:
/// raw -> short-window median -> EMA. Both intermediate outputs are exposed
/// under separate names; the raw value is never overwritten.
struct DistanceFilterPipeline {
    private var medianFilter: MedianWindowFilter
    private var emaFilter: ExponentialMovingAverageFilter

    private(set) var lastRaw: Double?
    private(set) var lastMedian: Double?
    private(set) var lastEMA: Double?

    init(config: MeasurementConfig) {
        medianFilter = MedianWindowFilter(windowSize: config.medianFilterWindowSize)
        emaFilter = ExponentialMovingAverageFilter(alpha: config.emaAlpha)
    }

    /// Feeds one valid raw sample through the chain.
    mutating func add(raw: Double) {
        lastRaw = raw
        let med = medianFilter.add(raw)
        lastMedian = med
        lastEMA = emaFilter.add(med)
    }

    mutating func reset() {
        medianFilter.reset()
        emaFilter.reset()
        lastRaw = nil
        lastMedian = nil
        lastEMA = nil
    }
}
