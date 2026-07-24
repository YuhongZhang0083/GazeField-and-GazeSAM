import Foundation

/// A finished recording with everything needed for review and export.
struct RecordedSession {
    var metadata: SessionMetadata
    var configuration: MeasurementConfig
    var neutralPose: NeutralPose?
    var acceptedSamples: [MeasurementSample]
    var rejectedSamples: [MeasurementSample]
    var summary: SessionSummary
    /// Guided-protocol state transitions with reasons (why each stage
    /// advanced, paused, resumed, or retried). Additive to the export format.
    var stageTransitions: [GuidedMovementController.StageTransition] = []
}

/// Accumulates samples during a recording. Rejected samples are kept in a
/// separate debug log — nothing is silently discarded — and excluded from the
/// default clean export.
final class SessionRecorder {
    private(set) var acceptedSamples: [MeasurementSample] = []
    private(set) var rejectedSamples: [MeasurementSample] = []
    let startedAt: Date

    init(startedAt: Date = Date()) {
        self.startedAt = startedAt
        acceptedSamples.reserveCapacity(2048)
        rejectedSamples.reserveCapacity(512)
    }

    var acceptedCount: Int { acceptedSamples.count }
    var rejectedCount: Int { rejectedSamples.count }

    func add(_ sample: MeasurementSample) {
        if sample.sampleValid {
            acceptedSamples.append(sample)
        } else {
            rejectedSamples.append(sample)
        }
    }

    func finish(metadata: SessionMetadata,
                configuration: MeasurementConfig,
                neutralPose: NeutralPose?,
                durationSeconds: Double,
                stageTransitions: [GuidedMovementController.StageTransition] = []) -> RecordedSession {
        var meta = metadata
        meta.durationSeconds = durationSeconds
        meta.trueDepthSurfaceAvailable = (acceptedSamples + rejectedSamples)
            .contains { $0.trueDepthSurfaceRawMeters != nil }
        let summary = SessionSummary.compute(accepted: acceptedSamples,
                                             rejected: rejectedSamples,
                                             durationSeconds: durationSeconds)
        return RecordedSession(metadata: meta,
                               configuration: configuration,
                               neutralPose: neutralPose,
                               acceptedSamples: acceptedSamples,
                               rejectedSamples: rejectedSamples,
                               summary: summary,
                               stageTransitions: stageTransitions)
    }
}
