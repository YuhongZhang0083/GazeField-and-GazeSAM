import Foundation

/// Small robust-statistics helpers used for depth ROI aggregation, neutral
/// baselines, and session summaries.
enum Statistics {

    /// Median of the values. Returns nil for an empty array.
    /// Even-count arrays return the mean of the two central elements.
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 {
            return sorted[mid]
        }
        return (sorted[mid - 1] + sorted[mid]) / 2.0
    }

    static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Sample standard deviation (n - 1 denominator). Nil for count < 2.
    static func standardDeviation(_ values: [Double]) -> Double? {
        guard values.count >= 2, let m = mean(values) else { return nil }
        let sumSq = values.reduce(0) { $0 + ($1 - m) * ($1 - m) }
        return sqrt(sumSq / Double(values.count - 1))
    }

    /// Median after discarding `trimFraction` of the smallest and largest
    /// values (robust to outliers at both tails).
    static func trimmedMedian(_ values: [Double], trimFraction: Double = 0.1) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let drop = Int(Double(sorted.count) * max(0, min(0.45, trimFraction)))
        let trimmed = Array(sorted.dropFirst(drop).dropLast(drop))
        return median(trimmed.isEmpty ? sorted : trimmed)
    }
}
