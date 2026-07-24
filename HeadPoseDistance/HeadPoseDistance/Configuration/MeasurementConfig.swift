import Foundation

/// Central configuration for all measurement, filtering, validation, and
/// protocol parameters. Nothing in the UI or pipeline hard-codes thresholds;
/// everything reads from this structure so parameters can be tuned in one
/// place and are exported with every session for reproducibility.
struct MeasurementConfig: Codable, Equatable {

    // MARK: - Distance validity range (meters)

    /// Minimum plausible camera-to-face distance. Depth values below this are
    /// rejected as invalid (sensor noise, occlusion by a hand, etc.).
    var minValidDistanceMeters: Double = 0.15

    /// Maximum plausible camera-to-face distance for this protocol.
    var maxValidDistanceMeters: Double = 1.00

    // MARK: - TrueDepth ROI sampling

    /// Half-width of the square region of interest sampled from the depth map,
    /// in depth-map pixels. The ROI is (2r+1) x (2r+1) pixels centered on the
    /// projected face-reference point (approximately the nose bridge / mid-face).
    var depthROIRadiusPixels: Int = 8

    /// Minimum number of valid depth pixels required inside the ROI for the
    /// surface-distance estimate to be considered usable.
    var minValidDepthPixelCount: Int = 20

    /// Minimum fraction of valid pixels inside the ROI.
    var minValidDepthPixelRatio: Double = 0.20

    /// Maximum allowed disagreement between the TrueDepth ROI median and the
    /// ARKit head-reference forward depth. Larger disagreement means the ROI
    /// projection likely landed off the face, so the surface value is marked
    /// unavailable rather than fabricated.
    var depthConsistencyToleranceMeters: Double = 0.10

    // MARK: - Distance filtering

    /// Number of most-recent valid samples used by the median filter.
    var medianFilterWindowSize: Int = 5

    /// Exponential-moving-average smoothing factor (0 < alpha <= 1).
    var emaAlpha: Double = 0.2

    // MARK: - Distance stability thresholds

    /// Absolute deviation from the neutral baseline that triggers a warning.
    var distanceDeviationWarningMeters: Double = 0.02

    /// Fractional deviation from the neutral baseline that triggers a warning.
    var distanceDeviationWarningFraction: Double = 0.05

    /// Absolute deviation from the neutral baseline beyond which a sample is
    /// rejected outright (torso moved, not just head rotation).
    var distanceDeviationRejectMeters: Double = 0.10

    // MARK: - Neutral capture

    /// Length of the neutral-pose capture window in seconds.
    var neutralCaptureDurationSeconds: Double = 2.0

    /// Minimum number of accepted samples for a valid neutral capture.
    var neutralMinSampleCount: Int = 30

    /// Maximum median head angular velocity during neutral capture (deg/s).
    var neutralMaxAngularVelocityDegPerSec: Double = 10.0

    /// Maximum allowed (max - min) head-reference distance range during
    /// neutral capture (meters).
    var neutralMaxDistanceRangeMeters: Double = 0.02

    /// Minimum fraction of neutral-capture samples during which the phone was
    /// stable.
    var neutralMinPhoneStableRatio: Double = 0.8

    // MARK: - Head motion limits during recording

    /// Head angular velocity above which a sample is rejected (deg/s).
    /// Slow deliberate head rotation is expected to stay well below this.
    var maxHeadAngularVelocityDegPerSec: Double = 120.0

    // MARK: - Phone motion thresholds (Core Motion)

    /// Rotation-rate magnitude (rad/s) above which movement is "minor".
    var phoneRotationRateMinorRadPerSec: Double = 0.05

    /// Rotation-rate magnitude (rad/s) above which movement is "excessive".
    var phoneRotationRateExcessiveRadPerSec: Double = 0.30

    /// User-acceleration magnitude (g) above which movement is "minor".
    var phoneAccelerationMinorG: Double = 0.02

    /// User-acceleration magnitude (g) above which movement is "excessive".
    var phoneAccelerationExcessiveG: Double = 0.10

    /// Attitude change from the recording-start reference (degrees) above
    /// which movement is "excessive" (the stand/phone was rotated).
    var phoneAttitudeChangeExcessiveDegrees: Double = 3.0

    // MARK: - Recording protocol timing (legacy)

    /// Legacy fixed-schedule hold time. No longer drives stage progression —
    /// the guided protocol is pose-driven (see below). Kept so exported
    /// configurations remain comparable across app versions.
    var directionHoldSeconds: Double = 1.8

    /// Legacy fixed-schedule center hold time (same note as above).
    var centerHoldSeconds: Double = 1.2

    // MARK: - Guided protocol (pose-driven stage progression)

    /// The pose must stay inside the target angular range for this long
    /// before a directional stage counts as completed.
    var targetHoldSeconds: Double = 1.2

    /// The head must stay near neutral for this long before the next
    /// directional stage begins.
    var neutralHoldSeconds: Double = 0.8

    /// Fraction of the target angle at which the user counts as having
    /// started moving (instructing → moving).
    var movementStartFraction: Double = 0.15

    /// Rotation opposite to the requested direction beyond which the UI shows
    /// wrong-direction feedback (degrees).
    var wrongDirectionThresholdDegrees: Double = 8.0

    /// Head angular velocity above which the guidance asks the user to slow
    /// down (deg/s). Distinct from the much higher sample-rejection limit.
    var guidedMaxAngularVelocityDegPerSec: Double = 45.0

    /// Generous per-stage timeout. Expiry NEVER auto-completes a stage — it
    /// records a timeout transition and restarts the stage (failure/retry).
    var stageTimeoutSeconds: Double = 30.0

    /// A gap between pipeline updates longer than this (app backgrounded,
    /// user pressed Pause) resets in-progress hold timers instead of counting
    /// the gap as held time.
    var updateGapResetSeconds: Double = 0.5

    // MARK: - Guided protocol distance boundary

    /// Deviation from the neutral baseline distance beyond which guided
    /// progression pauses (meters). Hysteresis: resuming requires coming back
    /// within `guidedDistanceExitBandMeters`.
    var guidedDistanceBandMeters: Double = 0.08

    /// The deviation must fall back below this before a distance pause lifts.
    /// Must be < `guidedDistanceBandMeters` (hysteresis gap prevents flicker).
    var guidedDistanceExitBandMeters: Double = 0.06

    /// The deviation must stay beyond the band this long before pausing
    /// (temporal stability — a single noisy frame never pauses).
    var distancePauseEnterSeconds: Double = 0.5

    /// The deviation must stay inside the exit band this long before
    /// resuming.
    var distancePauseExitSeconds: Double = 0.6

    // MARK: - Face alignment (pre-neutral positioning aid)

    /// Preferred absolute face distance range before a neutral baseline
    /// exists (meters). Used by the alignment boundary to say "move
    /// closer/farther" during setup.
    var preferredMinDistanceMeters: Double = 0.30
    var preferredMaxDistanceMeters: Double = 0.55

    /// Lateral/vertical face offset from the camera axis beyond which the
    /// alignment boundary asks the user to re-center (meters).
    var lateralOffsetToleranceMeters: Double = 0.05

    // MARK: - Screen-offset calibration

    /// Number of stable TrueDepth samples collected for the optional
    /// one-point screen-distance offset calibration.
    var offsetCalibrationSampleCount: Int = 45

    // MARK: - Head-direction targets

    /// Rotation the participant is asked to reach for each directional phase
    /// (degrees along the target axis). Diagonal phases use the same magnitude
    /// measured along the diagonal.
    var targetAngleDegrees: Double = 20.0

    /// Maximum rotation perpendicular to the requested axis before the UI
    /// warns that the movement has drifted off-axis.
    var maxOffAxisDegrees: Double = 12.0

    /// Total deviation from neutral below which the head counts as re-centered
    /// during a center phase.
    var centerToleranceDegrees: Double = 5.0

    // MARK: - UI

    /// Diameter of the fixed central fixation dot, in points (16–20 pt spec).
    var dotDiameterPoints: Double = 18.0

    static let `default` = MeasurementConfig()
}
