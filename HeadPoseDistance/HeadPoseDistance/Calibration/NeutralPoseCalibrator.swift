import Foundation
import simd

/// Robustly aggregated neutral head pose captured while the user looks at the
/// center dot with the head naturally centered.
struct NeutralPose: Codable, Equatable {
    /// Quaternion components [x, y, z, w] of the neutral cameraFromFace
    /// rotation (robust average, NOT an Euler-angle mean).
    var quaternion: [Float]
    /// Median camera-relative translation [x, y, z] in meters.
    var translation: [Float]
    /// Raw SDK-derived Euler angles of the neutral rotation (degrees),
    /// for debugging and export.
    var rawYawDegrees: Double
    var rawPitchDegrees: Double
    var rawRollDegrees: Double
    /// Median head-reference distance during the capture window (meters).
    var baselineHeadReferenceDistanceMeters: Double
    /// Median TrueDepth face-surface distance during the window, when enough
    /// depth samples were valid (meters).
    var baselineSurfaceDistanceMeters: Double?
    var capturedAt: Date
    var acceptedSampleCount: Int

    var simdQuaternion: simd_quatf {
        simd_normalize(simd_quatf(ix: quaternion[0], iy: quaternion[1],
                                  iz: quaternion[2], r: quaternion[3]))
    }
}

enum NeutralCaptureError: Error, LocalizedError, Equatable {
    case tooFewSamples(Int)
    case headMoving
    case distanceUnstable
    case phoneMoving

    var errorDescription: String? {
        switch self {
        case .tooFewSamples(let n):
            return "Not enough valid samples (\(n)). Keep your face visible and try again."
        case .headMoving:
            return "Head was moving during capture. Hold still and try again."
        case .distanceUnstable:
            return "Distance changed during capture. Hold still and try again."
        case .phoneMoving:
            return "The phone was moving during capture. Place it on a stand and try again."
        }
    }
}

/// Collects per-frame candidates during the ~2 s neutral window and produces
/// a robust neutral pose. Orientation aggregation is quaternion-aware
/// (sign-aligned component mean); Euler angles are never averaged.
final class NeutralPoseCalibrator {

    struct Candidate {
        var quaternion: simd_quatf
        var translation: SIMD3<Float>
        var headReferenceDistanceMeters: Double
        var surfaceDistanceMeters: Double?
        var angularVelocityDegPerSec: Double?
        var phoneStable: Bool
        var timestamp: TimeInterval
    }

    private(set) var candidates: [Candidate] = []
    let startedAtFrameTime: TimeInterval

    init(startedAtFrameTime: TimeInterval) {
        self.startedAtFrameTime = startedAtFrameTime
    }

    func add(_ candidate: Candidate) {
        candidates.append(candidate)
    }

    var sampleCount: Int { candidates.count }

    /// Validates the window and aggregates the neutral pose.
    /// Pure aggregation logic (given candidates) — unit-testable.
    func finalize(config: MeasurementConfig, capturedAt: Date = Date()) -> Result<NeutralPose, NeutralCaptureError> {
        Self.aggregate(candidates: candidates, config: config, capturedAt: capturedAt)
    }

    static func aggregate(candidates: [Candidate],
                          config: MeasurementConfig,
                          capturedAt: Date = Date()) -> Result<NeutralPose, NeutralCaptureError> {
        guard candidates.count >= config.neutralMinSampleCount else {
            return .failure(.tooFewSamples(candidates.count))
        }

        // Head must be still: median |angular velocity| below threshold.
        let velocities = candidates.compactMap { $0.angularVelocityDegPerSec }
        if let medianVelocity = Statistics.median(velocities),
           medianVelocity > config.neutralMaxAngularVelocityDegPerSec {
            return .failure(.headMoving)
        }

        // Distance must be stable: total range below threshold.
        let distances = candidates.map { $0.headReferenceDistanceMeters }
        if let minD = distances.min(), let maxD = distances.max(),
           maxD - minD > config.neutralMaxDistanceRangeMeters {
            return .failure(.distanceUnstable)
        }

        // Phone must be mostly stable during the window.
        let stableCount = candidates.filter { $0.phoneStable }.count
        if Double(stableCount) / Double(candidates.count) < config.neutralMinPhoneStableRatio {
            return .failure(.phoneMoving)
        }

        guard let avgQuat = MathSupport.averageQuaternion(candidates.map { $0.quaternion }) else {
            return .failure(.tooFewSamples(candidates.count))
        }

        let tx = Statistics.median(candidates.map { Double($0.translation.x) }) ?? 0
        let ty = Statistics.median(candidates.map { Double($0.translation.y) }) ?? 0
        let tz = Statistics.median(candidates.map { Double($0.translation.z) }) ?? 0
        let baselineDistance = Statistics.median(distances) ?? 0

        // Surface baseline only when at least half the window had valid depth.
        let surfaceValues = candidates.compactMap { $0.surfaceDistanceMeters }
        let baselineSurface: Double? = surfaceValues.count * 2 >= candidates.count
            ? Statistics.median(surfaceValues)
            : nil

        let rawEuler = HeadPoseEstimator.eulerAngles(from: avgQuat)

        let pose = NeutralPose(
            quaternion: [avgQuat.vector.x, avgQuat.vector.y, avgQuat.vector.z, avgQuat.vector.w],
            translation: [Float(tx), Float(ty), Float(tz)],
            rawYawDegrees: rawEuler.yawDegrees,
            rawPitchDegrees: rawEuler.pitchDegrees,
            rawRollDegrees: rawEuler.rollDegrees,
            baselineHeadReferenceDistanceMeters: baselineDistance,
            baselineSurfaceDistanceMeters: baselineSurface,
            capturedAt: capturedAt,
            acceptedSampleCount: candidates.count)
        return .success(pose)
    }
}
