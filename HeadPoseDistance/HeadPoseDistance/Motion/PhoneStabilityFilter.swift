import Foundation

/// Temporal smoothing + hysteresis for phone-stability classification.
///
/// The raw per-frame `DeviceMotionMonitor.stability(...)` reacts to a single
/// noisy Core Motion sample, so a momentary spike (a tap on the screen, a
/// truck driving past) could flip the state to `.excessive` and needlessly
/// pause the guided protocol. This filter damps that in two independent ways:
///
/// 1. **EMA smoothing** of the rotation-rate and acceleration magnitudes, so
///    isolated spikes are averaged down before classification.
/// 2. **Temporal hysteresis** on the `.excessive` verdict: the smoothed signal
///    must read excessive continuously for `phoneExcessiveEnterSeconds`
///    before the filter reports `.excessive`, and must read calm continuously
///    for `phoneExcessiveExitSeconds` before that verdict is released. Between
///    those, the previous verdict is held, so the classification never
///    flickers frame-to-frame.
///
/// Pure and deterministic given a timestamped sequence — unit-testable
/// without Core Motion.
final class PhoneStabilityFilter {

    private var emaRotation: Double?
    private var emaAcceleration: Double?
    private var held: PhoneStability = .unknown
    private var excessiveSince: TimeInterval?
    private var calmSince: TimeInterval?
    private var lastTimestamp: TimeInterval?

    func reset() {
        emaRotation = nil
        emaAcceleration = nil
        held = .unknown
        excessiveSince = nil
        calmSince = nil
        lastTimestamp = nil
    }

    /// Feeds one motion sample and returns the debounced stability verdict.
    func update(rotationRateMagnitude: Double,
                accelerationMagnitude: Double,
                attitudeChangeDegrees: Double?,
                timestamp: TimeInterval,
                config: MeasurementConfig) -> PhoneStability {

        // A long gap (backgrounding, paused session) invalidates the running
        // averages and the dwell timers — start fresh rather than treating the
        // gap as sustained motion.
        if let last = lastTimestamp, timestamp - last > config.updateGapResetSeconds {
            emaRotation = nil
            emaAcceleration = nil
            excessiveSince = nil
            calmSince = nil
        }
        lastTimestamp = timestamp

        let alpha = min(max(config.phoneMotionSmoothingAlpha, 0.01), 1.0)
        let smoothedRotation = ema(&emaRotation, rotationRateMagnitude, alpha)
        let smoothedAcceleration = ema(&emaAcceleration, accelerationMagnitude, alpha)

        let raw = DeviceMotionMonitor.stability(
            rotationRateMagnitude: smoothedRotation,
            accelerationMagnitude: smoothedAcceleration,
            // Attitude change is already an absolute, slow-moving quantity;
            // it is not smoothed but is still debounced below.
            attitudeChangeDegrees: attitudeChangeDegrees,
            config: config)

        if raw == .excessive {
            calmSince = nil
            if excessiveSince == nil { excessiveSince = timestamp }
            if timestamp - (excessiveSince ?? timestamp) >= config.phoneExcessiveEnterSeconds {
                held = .excessive
            }
        } else {
            excessiveSince = nil
            if held == .excessive {
                // Require sustained calm before releasing the pause verdict.
                if calmSince == nil { calmSince = timestamp }
                if timestamp - (calmSince ?? timestamp) >= config.phoneExcessiveExitSeconds {
                    held = raw
                    calmSince = nil
                }
            } else {
                held = raw
                calmSince = nil
            }
        }
        return held
    }

    private func ema(_ store: inout Double?, _ value: Double, _ alpha: Double) -> Double {
        let smoothed = store.map { alpha * value + (1 - alpha) * $0 } ?? value
        store = smoothed
        return smoothed
    }
}
