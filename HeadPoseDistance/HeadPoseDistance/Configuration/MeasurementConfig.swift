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

    /// Absolute deviation from the neutral baseline (head-reference distance,
    /// which is stable under head rotation) beyond which a sample is rejected
    /// outright — the participant physically moved closer/farther from the
    /// screen rather than merely rotating the head. Tight, because the whole
    /// point of the guided protocol is to hold the neutral distance.
    var distanceDeviationRejectMeters: Double = 0.04

    /// Lateral/vertical face displacement from the neutral position beyond
    /// which a sample is rejected (the face slid out of the fixed bounds).
    var lateralDeviationRejectMeters: Double = 0.05

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

    // MARK: - Phone motion smoothing (PhoneStabilityFilter)

    /// EMA smoothing factor for the phone rotation-rate and acceleration
    /// magnitudes before stability classification. Lower = smoother / less
    /// twitchy (0 < alpha <= 1).
    var phoneMotionSmoothingAlpha: Double = 0.25

    /// The smoothed signal must read excessive continuously for this long
    /// before the filter reports `.excessive` (debounce-in).
    var phoneExcessiveEnterSeconds: Double = 0.35

    /// Once excessive, the signal must read calm continuously for this long
    /// before the verdict is released (debounce-out / hysteresis).
    var phoneExcessiveExitSeconds: Double = 0.7

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

    /// Deviation from the neutral baseline distance (head-reference, stable
    /// under head rotation) beyond which guided progression pauses and shows
    /// "move closer/farther" (meters). Hysteresis: resuming requires coming
    /// back within `guidedDistanceExitBandMeters`. Kept in step with
    /// `distanceDeviationRejectMeters` so the moment progression pauses is
    /// also the moment samples start being rejected.
    var guidedDistanceBandMeters: Double = 0.04

    /// The deviation must fall back below this before a distance pause lifts.
    /// Must be < `guidedDistanceBandMeters` (hysteresis gap prevents flicker).
    var guidedDistanceExitBandMeters: Double = 0.03

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

    /// Lateral/vertical face offset beyond which the alignment boundary asks
    /// the user to re-center (meters). Measured from the NEUTRAL face position
    /// once a neutral baseline exists (the fixed up/down/left/right bounds for
    /// the turning phase), and from the camera axis before that.
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

    // MARK: - Free exploration / coverage

    /// Extent of the (yaw, pitch) field the participant must cover, as a
    /// half-range in degrees. **Square**: vertical extent matches horizontal, so
    /// the field covers as much of the upper and lower FOV as it does left and
    /// right.
    ///
    /// ±32° pushes to the practical ceiling. The binding limits are the eye
    /// (comfortable rotation ~±30°, mechanical ~±45°) and ARKit face tracking,
    /// which starts losing the face somewhere past ~±35° of yaw. Going wider
    /// would add cells nobody can reach with the dot still fixated.
    var coverageYawAmplitudeDegrees: Double = 32.0
    var coveragePitchAmplitudeDegrees: Double = 32.0

    /// Largest combined rotation, √(yaw² + pitch²), a cell may sit at and still
    /// be required. This is a **physiological** limit, not a shape preference:
    /// the reachable region of the (yaw, pitch) plane is a disc, because what
    /// bounds it is total eye-in-head rotation.
    ///
    /// It matters once the field is wide. At ±32° the box corners demand 42.6°
    /// of combined rotation — past the eye's mechanical range while holding
    /// fixation — so requiring them would stall every session. At 34° the
    /// required region still **strictly contains** the previous ±25° square
    /// field (whose farthest cell centre was 32.6°) while reaching 30.1° along
    /// each axis instead of 23.1°.
    ///
    /// Set very large (e.g. 1000) to require the full rectangle.
    var coverageMaxCombinedDegrees: Double = 34.0

    /// Grid resolution: 17 × 17 over the ±32° field gives 289 cells of 3.76°
    /// each — 249 of them required, once the 34° reachability cap is applied — so
    /// the largest possible unmeasured hole, half a cell diagonal, is 2.66°,
    /// inside the heatmap kernel's `--sigma-min 3`. 17 is the smallest odd count
    /// that holds the cell size (and hence that guarantee) at the wider extent.
    ///
    /// Odd counts on purpose: an even grid puts a cell *boundary* at neutral, so
    /// the resting pose straddles two cells and the current-cell marker flickers
    /// between them. Odd gives a centre cell aligned with neutral.
    ///
    /// At the observed fill rate (~0.6 s per cell) this is a ~150 s session.
    /// Raising it further costs time roughly linearly and shrinks the on-screen
    /// cells below the size at which they can be told apart at the foveal scale
    /// the grid is drawn at.
    var coverageColumns: Int = 17
    var coverageRows: Int = 17

    /// Usable samples a cell needs before it counts as covered. At 60 Hz this
    /// is a ~0.13 s dwell requirement, which stops a fast swing through a cell
    /// from claiming it on one or two frames. Kept low because the grid is dense:
    /// 249 cells × 8 samples ≈ 33 s of pure dwell, with travel between cells
    /// dominating the real duration.
    var coverageSamplesPerCell: Int = 8

    /// Fraction of required cells that must be covered to finish. Not 1.0: with
    /// the corners required, the most extreme cells demand the largest combined
    /// rotation and are hard for some people even after the reachability cap;
    /// demanding every one would stall the session indefinitely. At 249 required
    /// cells this allows 24 misses — enough to absorb an entire 17-cell edge row,
    /// which is the realistic failure mode (downward pitch needs the eye to roll
    /// up, its most limited direction). Stopping early is always safe because
    /// per-sample coverage is exported.
    var coverageCompletionFraction: Double = 0.90

    /// How long the opening caption stays up after exploration starts, before
    /// the coverage grid is left to carry the state.
    ///
    /// The caption sits below the fixation dot, so *reading* it breaks
    /// fixation — a standing instruction next to a fixation target works
    /// against the measurement (the same reason the standing red-dot caption
    /// was removed).
    var explorationInstructionSeconds: Double = 6.0

    // MARK: - UI

    /// Vertical position of the TrueDepth camera centre, in global display
    /// points (y measured from the top of the display). On Face ID iPhones the
    /// camera sits in the notch / Dynamic Island near the top.
    ///
    /// Used to convert the fixation dot's on-screen position into a real offset
    /// from the camera axis, which is what makes the setup cue target the dot
    /// rather than the camera. Approximate and mildly device-dependent, but the
    /// quantity it corrects is ~230 pt, so a ±10 pt error here is a ~4% error on
    /// a few-centimetre correction — immaterial against a 5 cm tolerance.
    var cameraCenterYPoints: Double = 28.0

    /// Horizontal offset of the TrueDepth camera from the screen centreline, in
    /// points; positive = right of centre.
    ///
    /// The camera is not on the phone's centreline: inside the notch / Dynamic
    /// Island the Face ID sensors and the front camera sit side by side, and
    /// ARKit's face anchor is expressed in the front camera's frame. A face
    /// centred on the screen therefore reads as offset toward the opposite side —
    /// which is exactly the leftward bias observed on device.
    ///
    /// 47 pt ≈ 7.8 mm, an estimate of the camera's position within a ~122 pt
    /// Dynamic Island. Approximate and device-dependent; the sign is what matters
    /// most and is corroborated by the observed direction of the bias. Verify by
    /// centring deliberately and checking the head sits centred in the oval.
    var cameraCenterXOffsetPoints: Double = 47.0

    /// Diameter of the fixed central fixation dot, in points (16–20 pt spec).
    var dotDiameterPoints: Double = 18.0

    /// Vertical position of the fixation dot (and the head/oval cluster
    /// centered on it) as a fraction of screen height. Placed in the upper
    /// third, near the TrueDepth camera: fixating there keeps the gaze line
    /// close to the camera axis, which improves tracking quality and removes
    /// the downward eye posture a screen-center dot would cause. The actual
    /// dot position is reported to the pipeline and exported in the session
    /// metadata (`dotCenterXPoints`/`dotCenterYPoints`).
    var dotAnchorYFraction: Double = 0.26

    static let `default` = MeasurementConfig()
}
