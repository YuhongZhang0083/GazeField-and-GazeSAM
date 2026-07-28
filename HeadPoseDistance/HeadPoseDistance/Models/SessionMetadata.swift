import Foundation

/// Anonymous, non-biometric session metadata exported with every session.
struct SessionMetadata: Codable {
    var sessionID: UUID = UUID()
    var deviceModelIdentifier: String = DeviceInfo.modelIdentifier
    var systemVersion: String = DeviceInfo.systemVersion
    var appVersion: String = DeviceInfo.appVersion

    /// Usable screen size in points and the display scale.
    var screenWidthPoints: Double = 0
    var screenHeightPoints: Double = 0
    var screenScale: Double = 0
    var interfaceOrientation: String = "portrait"

    /// Center of the fixed red fixation dot, in screen points (global
    /// coordinate space).
    var dotCenterXPoints: Double = 0
    var dotCenterYPoints: Double = 0

    /// Which recording protocol produced this session, so a CSV is always
    /// self-describing when the two modes are compared.
    var recordingMode: String = RecordingMode.spiralSweep.rawValue

    var startedAt: Date = Date()
    var durationSeconds: Double = 0

    /// Whether per-pixel TrueDepth surface distance was ever available during
    /// the session.
    var trueDepthSurfaceAvailable: Bool = false

    /// Device-specific camera-behind-screen offset in effect (meters) and
    /// whether it came from the one-point user calibration (false = default
    /// 0.0, "uncalibrated").
    var cameraBehindScreenOffsetMeters: Double = 0
    var screenOffsetCalibrated: Bool = false
}
