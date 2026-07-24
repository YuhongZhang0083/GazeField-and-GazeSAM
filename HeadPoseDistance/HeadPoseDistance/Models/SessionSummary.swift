import Foundation

/// Aggregate statistics for a completed recording.
struct SessionSummary: Codable {
    var durationSeconds: Double
    var totalSamples: Int
    var acceptedSamples: Int
    var rejectedSamples: Int
    var meanSamplingRateHz: Double

    var medianHeadReferenceDistanceMeters: Double?
    var medianSurfaceDistanceMeters: Double?
    var medianEstimatedScreenDistanceMeters: Double?
    var distanceStandardDeviationMeters: Double?
    var distanceMinMeters: Double?
    var distanceMaxMeters: Double?

    var maxAbsoluteRelativeYawDegrees: Double?
    var maxAbsoluteRelativePitchDegrees: Double?
    var maxAbsoluteRelativeRollDegrees: Double?

    /// Percentage of all samples during which the phone was stable.
    var phoneStablePercentage: Double
    /// Percentage of all samples with a valid TrueDepth surface distance.
    var validTrueDepthPercentage: Double
    /// Reason string -> occurrence count, over all samples.
    var rejectionReasonCounts: [String: Int]

    /// Computes the summary from recorded samples. Pure and unit-testable.
    static func compute(accepted: [MeasurementSample],
                        rejected: [MeasurementSample],
                        durationSeconds: Double) -> SessionSummary {
        let all = accepted + rejected
        let total = all.count

        // Prefer the surface distance for distance statistics; fall back to
        // head-reference when depth was unavailable.
        let surface = accepted.compactMap { $0.trueDepthSurfaceRawMeters }
        let headRef = accepted.compactMap { $0.headReferenceDistanceMeters }
        let distanceSeries = surface.count >= max(10, headRef.count / 2) ? surface : headRef

        var reasonCounts: [String: Int] = [:]
        for sample in all {
            for reason in sample.rejectionReasons {
                reasonCounts[reason, default: 0] += 1
            }
        }

        let stableCount = all.filter { $0.phoneStable }.count
        let depthCount = all.filter { $0.trueDepthSurfaceRawMeters != nil }.count

        return SessionSummary(
            durationSeconds: durationSeconds,
            totalSamples: total,
            acceptedSamples: accepted.count,
            rejectedSamples: rejected.count,
            meanSamplingRateHz: durationSeconds > 0 ? Double(total) / durationSeconds : 0,
            medianHeadReferenceDistanceMeters: Statistics.median(headRef),
            medianSurfaceDistanceMeters: Statistics.median(surface),
            medianEstimatedScreenDistanceMeters: Statistics.median(
                accepted.compactMap { $0.estimatedScreenToFaceMeters }),
            distanceStandardDeviationMeters: Statistics.standardDeviation(distanceSeries),
            distanceMinMeters: distanceSeries.min(),
            distanceMaxMeters: distanceSeries.max(),
            maxAbsoluteRelativeYawDegrees: accepted.compactMap { $0.relativeYawDegrees }
                .map(abs).max(),
            maxAbsoluteRelativePitchDegrees: accepted.compactMap { $0.relativePitchDegrees }
                .map(abs).max(),
            maxAbsoluteRelativeRollDegrees: accepted.compactMap { $0.relativeRollDegrees }
                .map(abs).max(),
            phoneStablePercentage: total > 0 ? 100.0 * Double(stableCount) / Double(total) : 0,
            validTrueDepthPercentage: total > 0 ? 100.0 * Double(depthCount) / Double(total) : 0,
            rejectionReasonCounts: reasonCounts)
    }
}
