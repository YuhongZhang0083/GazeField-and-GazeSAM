import Foundation

/// Manages the device-specific camera-behind-screen offset used to convert a
/// TrueDepth camera-to-face distance into an estimated screen-to-face
/// distance.
///
///     estimatedScreenToFace = trueDepthFaceSurface - cameraBehindScreenOffset
///
/// One-point manual calibration:
/// 1. The user positions their face at a ruler-measured distance from the
///    SCREEN and enters that distance in centimeters.
/// 2. The app collects a burst of stable TrueDepth camera-distance samples.
/// 3.     offset = median(cameraDepthSamples) - enteredScreenDistance
/// 4. The offset is stored locally (UserDefaults) for this device.
///
/// With offset == 0 and no calibration, results are labeled
/// "Estimated screen distance — uncalibrated".
enum OffsetCalibrationError: Error, LocalizedError, Equatable {
    case notEnoughStableSamples

    var errorDescription: String? {
        switch self {
        case .notEnoughStableSamples:
            return "Could not collect enough stable TrueDepth samples. Check that your face is tracked and try again."
        }
    }
}

enum ScreenDistanceCalibrator {

    private static let offsetKey = "HeadPoseDistance.cameraBehindScreenOffsetMeters"
    private static let calibratedKey = "HeadPoseDistance.screenOffsetCalibrated"

    /// Pure computation, unit-testable.
    static func computeOffset(medianCameraDepthMeters: Double,
                              referenceScreenDistanceMeters: Double) -> Double {
        medianCameraDepthMeters - referenceScreenDistanceMeters
    }

    static func loadOffset() -> (offsetMeters: Double, calibrated: Bool) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: calibratedKey) else { return (0.0, false) }
        return (defaults.double(forKey: offsetKey), true)
    }

    static func save(offsetMeters: Double) {
        let defaults = UserDefaults.standard
        defaults.set(offsetMeters, forKey: offsetKey)
        defaults.set(true, forKey: calibratedKey)
    }

    static func reset() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: offsetKey)
        defaults.set(false, forKey: calibratedKey)
    }
}
