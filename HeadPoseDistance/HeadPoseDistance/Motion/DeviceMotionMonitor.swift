import Foundation
import CoreMotion
import simd

/// Phone-stability classification derived from Core Motion.
enum PhoneStability: String, Codable {
    case unknown
    case stable
    case minor
    case excessive

    var label: String {
        switch self {
        case .unknown: return "Phone Motion Unknown"
        case .stable: return "Phone Stable"
        case .minor: return "Minor Phone Movement"
        case .excessive: return "Excessive Phone Movement"
        }
    }
}

/// Monitors whether the phone itself stays stationary so that phone movement
/// is never confused with head movement. Small hand tremor is tolerated by
/// the "minor" band; only meaningful device movement is flagged excessive.
final class DeviceMotionMonitor {

    /// Immutable snapshot of the latest motion state, safe to read from the
    /// AR processing queue.
    struct Snapshot {
        var timestamp: TimeInterval
        var rotationRate: SIMD3<Double>          // rad/s
        var userAcceleration: SIMD3<Double>      // g
        var gravity: SIMD3<Double>               // g
        var attitudeQuaternion: simd_quatd
        /// Rotation (degrees) between the current attitude and the reference
        /// attitude captured at recording start. Nil before a reference is set.
        var attitudeChangeFromReferenceDegrees: Double?

        var rotationRateMagnitude: Double { simd_length(rotationRate) }
        var userAccelerationMagnitude: Double { simd_length(userAcceleration) }
    }

    private let motionManager = CMMotionManager()
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var latestSnapshot: Snapshot?
    private var referenceAttitude: simd_quatd?

    var isAvailable: Bool { motionManager.isDeviceMotionAvailable }

    func start() {
        guard motionManager.isDeviceMotionAvailable,
              !motionManager.isDeviceMotionActive else { return }
        queue.maxConcurrentOperationCount = 1
        motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
        motionManager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let q = motion.attitude.quaternion
            let attitude = simd_normalize(simd_quatd(ix: q.x, iy: q.y, iz: q.z, r: q.w))

            self.lock.lock()
            var change: Double?
            if let ref = self.referenceAttitude {
                let dot = min(1.0, abs(simd_dot(ref.vector, attitude.vector)))
                change = 2.0 * acos(dot) * 180.0 / .pi
            }
            self.latestSnapshot = Snapshot(
                timestamp: motion.timestamp,
                rotationRate: SIMD3(motion.rotationRate.x,
                                    motion.rotationRate.y,
                                    motion.rotationRate.z),
                userAcceleration: SIMD3(motion.userAcceleration.x,
                                        motion.userAcceleration.y,
                                        motion.userAcceleration.z),
                gravity: SIMD3(motion.gravity.x, motion.gravity.y, motion.gravity.z),
                attitudeQuaternion: attitude,
                attitudeChangeFromReferenceDegrees: change)
            self.lock.unlock()
        }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
    }

    /// Captures the current attitude as the "phone has not moved" reference.
    /// Call at recording start.
    func setReferenceAttitude() {
        lock.lock()
        referenceAttitude = latestSnapshot?.attitudeQuaternion
        lock.unlock()
    }

    func clearReferenceAttitude() {
        lock.lock()
        referenceAttitude = nil
        lock.unlock()
    }

    func latest() -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        return latestSnapshot
    }

    /// Classifies phone stability from a snapshot using configured thresholds.
    /// Pure function, unit-testable.
    ///
    /// The verdict is based on **actual motion** — rotation rate and user
    /// acceleration — only. Attitude drift from the recording-start reference
    /// is deliberately NOT part of it: a phone that is repositioned and then
    /// held still has near-zero rotation and acceleration but a non-zero
    /// attitude offset, and folding that offset in produced a permanent
    /// "Excessive Phone Movement" that never cleared and dead-locked the
    /// guided pause. The attitude change is still recorded on every sample
    /// (`phoneAttitudeChangeDegrees`) and shown in the debug view for offline
    /// data-quality analysis; it simply no longer labels a stationary phone as
    /// moving. `attitudeChangeDegrees` is retained in the signature for that
    /// recording path and for callers that pass it through.
    static func stability(rotationRateMagnitude: Double,
                          accelerationMagnitude: Double,
                          attitudeChangeDegrees: Double?,
                          config: MeasurementConfig) -> PhoneStability {
        if rotationRateMagnitude > config.phoneRotationRateExcessiveRadPerSec
            || accelerationMagnitude > config.phoneAccelerationExcessiveG {
            return .excessive
        }
        if rotationRateMagnitude > config.phoneRotationRateMinorRadPerSec
            || accelerationMagnitude > config.phoneAccelerationMinorG {
            return .minor
        }
        return .stable
    }
}
