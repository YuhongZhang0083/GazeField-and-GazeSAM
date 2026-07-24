import Foundation
import simd

/// Sign conventions used to map the camera-space face translation onto
/// user-facing "move left/right/up/down" cues.
///
/// ARKit's camera space is natively landscape-oriented; in portrait the
/// mapping below assumes camera **+x ≈ screen-down** and **+y ≈ screen-right**
/// (landscape-right sensor rotated 90° CW into portrait), and phrases cues in
/// the USER's frame (mirrored, matching what a selfie preview would show).
///
/// Like `HeadPoseConvention`, these multipliers are a documented assumption
/// pending physical-device verification — if a cue reads backwards on
/// hardware, flip the corresponding sign here and nowhere else.
struct AlignmentConvention: Codable, Equatable {
    /// userRightMeters = userRightFromCameraY * translation.y
    var userRightFromCameraY: Double = 1.0
    /// userUpMeters = userUpFromCameraX * translation.x
    var userUpFromCameraX: Double = -1.0

    static let `default` = AlignmentConvention()
}

/// Result of one alignment evaluation — everything the boundary UI shows.
struct FaceAlignmentState: Equatable {
    enum DistanceStatus: Equatable {
        case unknown
        case tooClose
        case tooFar
        case ok
    }

    var faceTracked = false
    var distanceStatus: DistanceStatus = .unknown
    /// Lateral face offset in the USER's frame (meters): + = user's right.
    var userRightOffsetMeters: Double?
    /// Vertical face offset in the USER's frame (meters): + = up.
    var userUpOffsetMeters: Double?
    var withinLateralTolerance = true
    /// Highest-priority short cue, or nil when nothing needs correcting.
    var cue: String?
    /// True when tracked, distance ok, and laterally within tolerance.
    var isAligned = false

    static let unknown = FaceAlignmentState()
}

/// Pure evaluator for the head-position/distance boundary. Uses measured
/// tracking data only — never the camera image.
enum FaceAlignmentEvaluator {

    /// - Parameters:
    ///   - primaryDistanceMeters: the currently selected primary distance
    ///     (filtered surface distance when TrueDepth is available, otherwise
    ///     the ARKit head-reference distance).
    ///   - deviationMeters: deviation from the neutral baseline, when a
    ///     baseline exists. Preferred over the absolute range once present.
    ///   - translation: camera-space face translation from the face anchor.
    static func evaluate(primaryDistanceMeters: Double?,
                         deviationMeters: Double?,
                         translation: SIMD3<Float>?,
                         faceTracked: Bool,
                         config: MeasurementConfig,
                         convention: AlignmentConvention = .default) -> FaceAlignmentState {
        var state = FaceAlignmentState()
        state.faceTracked = faceTracked
        guard faceTracked else {
            state.cue = "Face not tracked"
            return state
        }

        // --- Distance ---
        if let deviation = deviationMeters {
            // Baseline exists: judge against the guided band.
            if deviation > config.guidedDistanceBandMeters {
                state.distanceStatus = .tooFar
            } else if deviation < -config.guidedDistanceBandMeters {
                state.distanceStatus = .tooClose
            } else {
                state.distanceStatus = .ok
            }
        } else if let distance = primaryDistanceMeters {
            // No baseline yet: guide into the preferred absolute range.
            if distance < config.preferredMinDistanceMeters {
                state.distanceStatus = .tooClose
            } else if distance > config.preferredMaxDistanceMeters {
                state.distanceStatus = .tooFar
            } else {
                state.distanceStatus = .ok
            }
        }

        // --- Lateral / vertical offset ---
        if let t = translation {
            let right = convention.userRightFromCameraY * Double(t.y)
            let up = convention.userUpFromCameraX * Double(t.x)
            state.userRightOffsetMeters = right
            state.userUpOffsetMeters = up
            state.withinLateralTolerance =
                abs(right) <= config.lateralOffsetToleranceMeters
                && abs(up) <= config.lateralOffsetToleranceMeters
        }

        // --- Cue, highest priority first: distance, then lateral. ---
        switch state.distanceStatus {
        case .tooFar:
            state.cue = "Move closer"
        case .tooClose:
            state.cue = "Move farther"
        case .ok, .unknown:
            if let right = state.userRightOffsetMeters,
               abs(right) > config.lateralOffsetToleranceMeters {
                state.cue = right > 0 ? "Move left" : "Move right"
            } else if let up = state.userUpOffsetMeters,
                      abs(up) > config.lateralOffsetToleranceMeters {
                state.cue = up > 0 ? "Move down" : "Move up"
            } else if state.distanceStatus == .ok {
                state.cue = nil  // aligned — UI may show "Hold position"
            }
        }

        state.isAligned = state.distanceStatus == .ok && state.withinLateralTolerance
        return state
    }
}
