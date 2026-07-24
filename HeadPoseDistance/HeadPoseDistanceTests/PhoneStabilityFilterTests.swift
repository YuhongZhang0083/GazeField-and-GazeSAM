import XCTest
@testable import HeadPoseDistance

/// Smoothing + hysteresis that stops isolated Core Motion spikes from
/// flashing "excessive phone movement" and pausing the protocol.
final class PhoneStabilityFilterTests: XCTestCase {

    private var config = MeasurementConfig.default

    private let calmRotation = 0.0
    private let calmAccel = 0.0

    /// A rotation magnitude comfortably above the excessive threshold.
    private var loudRotation: Double { config.phoneRotationRateExcessiveRadPerSec * 3 }

    /// Feeds a constant sample for `duration` at 60 Hz; returns the last verdict.
    @discardableResult
    private func feed(_ filter: PhoneStabilityFilter,
                      from start: TimeInterval,
                      duration: TimeInterval,
                      rotation: Double,
                      accel: Double = 0,
                      attitude: Double? = 0) -> PhoneStability {
        var verdict: PhoneStability = .unknown
        var t = start
        let step = 1.0 / 60.0
        repeat {
            verdict = filter.update(rotationRateMagnitude: rotation,
                                    accelerationMagnitude: accel,
                                    attitudeChangeDegrees: attitude,
                                    timestamp: t,
                                    config: config)
            t += step
        } while t <= start + duration
        return verdict
    }

    func testCalmSignalIsStable() {
        let filter = PhoneStabilityFilter()
        let verdict = feed(filter, from: 0, duration: 1.0, rotation: calmRotation)
        XCTAssertEqual(verdict, .stable)
    }

    /// Regression: a still phone that is merely tilted away from the
    /// recording-start reference (large attitude change, but zero rotation and
    /// acceleration) must read STABLE, not excessive. Previously the attitude
    /// term produced a permanent "Excessive Phone Movement".
    func testStillButTiltedPhoneIsStable() {
        let filter = PhoneStabilityFilter()
        let verdict = feed(filter, from: 0, duration: 1.0,
                           rotation: calmRotation, accel: 0,
                           attitude: config.phoneAttitudeChangeExcessiveDegrees * 10)
        XCTAssertEqual(verdict, .stable,
                       "a stationary phone must never be flagged as moving")
    }

    func testStabilityClassificationIgnoresAttitude() {
        // Same motion, wildly different attitude → identical verdict.
        let withoutTilt = DeviceMotionMonitor.stability(
            rotationRateMagnitude: 0, accelerationMagnitude: 0,
            attitudeChangeDegrees: 0, config: config)
        let withTilt = DeviceMotionMonitor.stability(
            rotationRateMagnitude: 0, accelerationMagnitude: 0,
            attitudeChangeDegrees: 45, config: config)
        XCTAssertEqual(withoutTilt, .stable)
        XCTAssertEqual(withTilt, .stable)
    }

    /// A spike shorter than the enter-dwell must NOT be reported as excessive.
    func testBriefSpikeDoesNotTripExcessive() {
        let filter = PhoneStabilityFilter()
        feed(filter, from: 0, duration: 0.5, rotation: calmRotation)
        // A single very short burst, well under phoneExcessiveEnterSeconds.
        let during = feed(filter, from: 0.5,
                          duration: config.phoneExcessiveEnterSeconds * 0.4,
                          rotation: loudRotation)
        XCTAssertNotEqual(during, .excessive,
                          "a brief spike must not pause the protocol")
    }

    /// Sustained motion beyond the dwell IS reported excessive.
    func testSustainedMotionTripsExcessive() {
        let filter = PhoneStabilityFilter()
        feed(filter, from: 0, duration: 0.5, rotation: calmRotation)
        let verdict = feed(filter, from: 0.5,
                           duration: config.phoneExcessiveEnterSeconds + 0.5,
                           rotation: loudRotation)
        XCTAssertEqual(verdict, .excessive)
    }

    /// Once excessive, a brief calm blip must not immediately release it.
    func testExcessiveHoldsThroughBriefCalm() {
        let filter = PhoneStabilityFilter()
        feed(filter, from: 0, duration: config.phoneExcessiveEnterSeconds + 0.5,
             rotation: loudRotation)
        let stillExcessive = feed(filter,
                                  from: 5,
                                  duration: config.phoneExcessiveExitSeconds * 0.4,
                                  rotation: calmRotation)
        XCTAssertEqual(stillExcessive, .excessive,
                       "must not release the pause on a momentary calm frame")
    }

    /// Sustained calm beyond the exit-dwell releases the excessive verdict.
    func testExcessiveReleasesAfterSustainedCalm() {
        let filter = PhoneStabilityFilter()
        feed(filter, from: 0, duration: config.phoneExcessiveEnterSeconds + 0.5,
             rotation: loudRotation)
        let released = feed(filter, from: 5,
                            duration: config.phoneExcessiveExitSeconds + 0.5,
                            rotation: calmRotation)
        XCTAssertNotEqual(released, .excessive)
        XCTAssertEqual(released, .stable)
    }

    /// EMA smoothing damps a one-frame spike: a lone loud sample between calm
    /// frames stays below the excessive threshold after smoothing.
    func testSingleFrameSpikeIsSmoothedAway() {
        let filter = PhoneStabilityFilter()
        feed(filter, from: 0, duration: 0.5, rotation: calmRotation)
        // One very loud frame, then straight back to calm.
        let spike = filter.update(rotationRateMagnitude: loudRotation * 5,
                                  accelerationMagnitude: 0,
                                  attitudeChangeDegrees: 0,
                                  timestamp: 0.6,
                                  config: config)
        XCTAssertNotEqual(spike, .excessive,
                          "one smoothed frame must not reach the excessive verdict")
    }

    /// A long gap (backgrounding / pause) resets timers so the gap isn't
    /// mistaken for sustained motion.
    func testGapResetsDwellTimers() {
        let filter = PhoneStabilityFilter()
        // Loud, but interrupted by a gap larger than the reset threshold, so
        // the enter-dwell can never accumulate across the gap.
        _ = filter.update(rotationRateMagnitude: loudRotation,
                          accelerationMagnitude: 0, attitudeChangeDegrees: 0,
                          timestamp: 0, config: config)
        let afterGap = filter.update(rotationRateMagnitude: loudRotation,
                                     accelerationMagnitude: 0, attitudeChangeDegrees: 0,
                                     timestamp: config.updateGapResetSeconds + 1.0,
                                     config: config)
        XCTAssertNotEqual(afterGap, .excessive,
                          "dwell must restart after a long gap, not carry across it")
    }

    func testResetReturnsToUnknown() {
        let filter = PhoneStabilityFilter()
        feed(filter, from: 0, duration: 1.0, rotation: calmRotation)
        filter.reset()
        // First sample after reset with a sustained-but-not-yet-dwelled spike
        // should not be excessive.
        let first = filter.update(rotationRateMagnitude: loudRotation,
                                  accelerationMagnitude: 0, attitudeChangeDegrees: 0,
                                  timestamp: 10, config: config)
        XCTAssertNotEqual(first, .excessive)
    }
}
