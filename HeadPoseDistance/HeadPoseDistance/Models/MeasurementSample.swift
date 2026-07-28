import Foundation

/// One recorded measurement. Contains only numerical measurements — never
/// images, meshes, or biometric templates. Raw and filtered values are kept
/// in separate fields; raw values are never overwritten.
struct MeasurementSample: Codable, Identifiable {
    var id: UUID = UUID()

    // MARK: Timing
    /// Wall-clock time (Unix epoch seconds) when the sample was processed.
    var timestampUnix: Double
    /// ARFrame.timestamp (device uptime seconds).
    var arFrameTimestamp: Double
    /// Seconds since recording started (pause time excluded).
    var sessionElapsedSeconds: Double

    // MARK: Protocol
    /// Active protocol phase label (movement instruction in effect).
    var protocolPhase: String

    // MARK: Raw transforms (column-major 4x4, meters) — JSON export only.
    var cameraTransform: [Float]?
    var faceAnchorTransform: [Float]?
    var cameraFromFaceTransform: [Float]?

    // MARK: Translation & distance (meters)
    var translationX: Double?
    var translationY: Double?
    var translationZ: Double?
    /// |z| of the camera-relative translation.
    var forwardDepthMeters: Double?
    /// Euclidean camera-to-face-origin distance ("Head reference distance").
    var headReferenceDistanceMeters: Double?
    /// Raw TrueDepth central-face surface distance ("TrueDepth face-surface
    /// distance"). Nil when depth was unavailable or failed validation.
    var trueDepthSurfaceRawMeters: Double?
    /// Median-filtered surface distance.
    var trueDepthSurfaceMedianFilteredMeters: Double?
    /// EMA-filtered surface distance (applied after the median filter).
    var trueDepthSurfaceEMAFilteredMeters: Double?
    /// surface − cameraBehindScreenOffset ("Estimated screen-to-face
    /// distance"; uncalibrated when the offset is 0).
    var estimatedScreenToFaceMeters: Double?
    /// Signed deviation from the neutral baseline distance.
    var distanceDeviationFromBaselineMeters: Double?

    // MARK: Head orientation
    /// Camera-relative face rotation quaternion.
    var quaternionX: Double?
    var quaternionY: Double?
    var quaternionZ: Double?
    var quaternionW: Double?
    /// Raw SDK-derived Euler angles (degrees, presentation decomposition
    /// R = Ry·Rx·Rz). Include the sensor-vs-portrait orientation offset.
    var rawYawDegrees: Double?
    var rawPitchDegrees: Double?
    var rawRollDegrees: Double?
    /// Neutral-relative angles in the user-facing convention
    /// (+yaw right, +pitch up, +roll toward right shoulder).
    var relativeYawDegrees: Double?
    var relativePitchDegrees: Double?
    var relativeRollDegrees: Double?
    /// Frame-to-frame head rotation speed (deg/s).
    var headAngularVelocityDegPerSec: Double?

    // MARK: Phone motion
    var phoneRotationRateMagnitudeRadPerSec: Double?
    var phoneAccelerationMagnitudeG: Double?
    var phoneAttitudeChangeDegrees: Double?

    // MARK: TrueDepth quality
    var trueDepthValidPixelCount: Int?
    var trueDepthValidPixelRatio: Double?

    // MARK: Flags
    var trackingValid: Bool
    var phoneStable: Bool
    var distanceStable: Bool
    var sampleValid: Bool
    /// 0…1 quality score (0 for rejected samples).
    var confidence: Double
    /// Stable machine-readable reason strings (see RejectionReason).
    var rejectionReasons: [String]

    // MARK: Spiral sweep (spiral-sweep mode only; nil in eight-spoke mode)

    /// 0…1 along the spiral path at this sample.
    var sweepProgress: Double?
    /// Where the guide was, in neutral-relative degrees. Together with the
    /// measured `relativeYaw/PitchDegrees` this gives the offline pipeline the
    /// intended path as well as the achieved one.
    var sweepTargetYawDegrees: Double?
    var sweepTargetPitchDegrees: Double?
    /// Angular distance from head to guide (degrees) — usable as a per-sample
    /// quality weight when fitting the gaze field.
    var sweepTrackingErrorDegrees: Double?
}
