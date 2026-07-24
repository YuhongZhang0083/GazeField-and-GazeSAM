import Foundation

/// Machine-readable reasons a sample was rejected or down-weighted.
enum RejectionReason: String, Codable, CaseIterable {
    // Hard-reject reasons.
    case faceNotTracked = "face_not_tracked"
    case invalidTransform = "invalid_transform"
    case invalidOrientation = "invalid_orientation"
    case distanceOutOfRange = "distance_out_of_range"
    case excessiveDistanceChange = "excessive_distance_change"
    case faceOutOfBounds = "face_out_of_lateral_bounds"
    case phoneMovementExcessive = "phone_movement_excessive"
    case headVelocityTooHigh = "head_velocity_too_high"
    case nonMonotonicTimestamp = "non_monotonic_timestamp"
    case sessionInterrupted = "session_interrupted"
    // Soft (down-weight) reasons — sample stays valid, confidence drops.
    case phoneMovementMinor = "phone_movement_minor"
    case depthUnavailable = "truedepth_unavailable"
    case insufficientDepthPixels = "insufficient_depth_pixels"
    case depthInconsistent = "depth_inconsistent_with_head_reference"
    case distanceDeviationWarning = "distance_deviation_warning"
}

struct ValidationResult: Equatable {
    var isValid: Bool
    /// 0…1, 0 for rejected samples.
    var confidence: Double
    /// All reasons, hard and soft, in a stable order.
    var reasons: [RejectionReason]
}

/// Everything the validator needs to judge one sample. Built by the pipeline;
/// pure data so validation is unit-testable.
struct ValidationInput {
    var faceTracked: Bool
    var transformFinite: Bool
    var orientationFinite: Bool
    var headReferenceDistanceMeters: Double?
    var distanceDeviationMeters: Double?
    var baselineDistanceMeters: Double?
    /// False when a neutral baseline exists and the face has slid outside the
    /// fixed lateral/vertical bounds. Nil/true before a baseline exists.
    var faceLaterallyInBounds: Bool = true
    var depthExpected: Bool
    var depthAvailable: Bool
    var depthValidPixelCount: Int?
    var depthValidPixelRatio: Double?
    var depthConsistent: Bool?
    var phoneStability: PhoneStability
    var headAngularVelocityDegPerSec: Double?
    var timestampMonotonic: Bool
    var interrupted: Bool
}

/// Applies the configured acceptance rules and computes a confidence score.
/// Rules follow the protocol: hard failures reject the sample; soft issues
/// keep it but lower confidence and are always recorded as reasons.
enum SampleValidator {

    static func validate(_ input: ValidationInput, config: MeasurementConfig) -> ValidationResult {
        var hard: [RejectionReason] = []
        var soft: [RejectionReason] = []
        var penalty = 0.0

        if !input.faceTracked { hard.append(.faceNotTracked) }
        if !input.transformFinite { hard.append(.invalidTransform) }
        if !input.orientationFinite { hard.append(.invalidOrientation) }
        if !input.timestampMonotonic { hard.append(.nonMonotonicTimestamp) }
        if input.interrupted { hard.append(.sessionInterrupted) }

        if let d = input.headReferenceDistanceMeters {
            if d < config.minValidDistanceMeters || d > config.maxValidDistanceMeters {
                hard.append(.distanceOutOfRange)
            }
        }

        // Distance deviation from baseline: warn band -> soft, beyond reject
        // band -> hard.
        if let deviation = input.distanceDeviationMeters,
           let baseline = input.baselineDistanceMeters {
            let absDev = abs(deviation)
            let warnThreshold = min(config.distanceDeviationWarningMeters,
                                    baseline * config.distanceDeviationWarningFraction)
            if absDev > config.distanceDeviationRejectMeters {
                hard.append(.excessiveDistanceChange)
            } else if absDev > warnThreshold {
                soft.append(.distanceDeviationWarning)
                penalty += 0.2
            }
        }

        // Face slid out of the fixed lateral/vertical bounds captured at
        // neutral — reject (the head is no longer positioned as at baseline).
        if !input.faceLaterallyInBounds {
            hard.append(.faceOutOfBounds)
        }

        switch input.phoneStability {
        case .excessive:
            hard.append(.phoneMovementExcessive)
        case .minor:
            soft.append(.phoneMovementMinor)
            penalty += 0.15
        case .stable, .unknown:
            break
        }

        if let v = input.headAngularVelocityDegPerSec {
            if v > config.maxHeadAngularVelocityDegPerSec {
                hard.append(.headVelocityTooHigh)
            } else if v > 0.8 * config.maxHeadAngularVelocityDegPerSec {
                penalty += 0.1
            }
        }

        // Depth issues never reject a sample on their own (surface distance is
        // optional); they are recorded and lower confidence.
        if input.depthExpected {
            if !input.depthAvailable {
                soft.append(.depthUnavailable)
                penalty += 0.1
            } else {
                if let count = input.depthValidPixelCount,
                   let ratio = input.depthValidPixelRatio,
                   count < config.minValidDepthPixelCount
                    || ratio < config.minValidDepthPixelRatio {
                    soft.append(.insufficientDepthPixels)
                    penalty += 0.1
                }
                if input.depthConsistent == false {
                    soft.append(.depthInconsistent)
                    penalty += 0.15
                }
            }
        }

        let isValid = hard.isEmpty
        let confidence = isValid ? max(0.05, 1.0 - penalty) : 0.0
        return ValidationResult(isValid: isValid,
                                confidence: confidence,
                                reasons: hard + soft)
    }
}
