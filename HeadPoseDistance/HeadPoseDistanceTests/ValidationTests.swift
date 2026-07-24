import XCTest
@testable import HeadPoseDistance

/// Sample validation rules and confidence scoring.
final class ValidationTests: XCTestCase {

    /// A fully healthy input; individual tests break one aspect at a time.
    private func healthyInput() -> ValidationInput {
        ValidationInput(faceTracked: true,
                        transformFinite: true,
                        orientationFinite: true,
                        headReferenceDistanceMeters: 0.4,
                        distanceDeviationMeters: 0.0,
                        baselineDistanceMeters: 0.4,
                        depthExpected: true,
                        depthAvailable: true,
                        depthValidPixelCount: 200,
                        depthValidPixelRatio: 0.9,
                        depthConsistent: true,
                        phoneStability: .stable,
                        headAngularVelocityDegPerSec: 20,
                        timestampMonotonic: true,
                        interrupted: false)
    }

    func testHealthySampleIsValidWithFullConfidence() {
        let result = SampleValidator.validate(healthyInput(), config: .default)
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.confidence, 1.0, accuracy: 1e-9)
        XCTAssertTrue(result.reasons.isEmpty)
    }

    func testFaceNotTrackedRejects() {
        var input = healthyInput()
        input.faceTracked = false
        let result = SampleValidator.validate(input, config: .default)
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.confidence, 0)
        XCTAssertTrue(result.reasons.contains(.faceNotTracked))
    }

    func testInvalidTransformRejects() {
        var input = healthyInput()
        input.transformFinite = false
        input.orientationFinite = false
        let result = SampleValidator.validate(input, config: .default)
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.reasons.contains(.invalidTransform))
        XCTAssertTrue(result.reasons.contains(.invalidOrientation))
    }

    func testDistanceOutOfRangeRejects() {
        var input = healthyInput()
        input.headReferenceDistanceMeters = 1.5     // above 1.0 m limit
        XCTAssertFalse(SampleValidator.validate(input, config: .default).isValid)
        input.headReferenceDistanceMeters = 0.10    // below 0.15 m limit
        XCTAssertFalse(SampleValidator.validate(input, config: .default).isValid)
    }

    func testExcessiveDistanceChangeRejects() {
        var input = healthyInput()
        input.distanceDeviationMeters = 0.06        // beyond the 4 cm reject band
        let result = SampleValidator.validate(input, config: .default)
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.reasons.contains(.excessiveDistanceChange))
    }

    func testDistanceDeviationWarningDownWeights() {
        var input = healthyInput()
        input.distanceDeviationMeters = 0.03        // warn band (> 2 cm, < 4 cm)
        let result = SampleValidator.validate(input, config: .default)
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.confidence, 0.8, accuracy: 1e-9)
        XCTAssertTrue(result.reasons.contains(.distanceDeviationWarning))
    }

    func testFaceOutOfLateralBoundsRejects() {
        var input = healthyInput()
        input.faceLaterallyInBounds = false
        let result = SampleValidator.validate(input, config: .default)
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.reasons.contains(.faceOutOfBounds))
    }

    func testPhoneMovement() {
        var input = healthyInput()
        input.phoneStability = .excessive
        let excessive = SampleValidator.validate(input, config: .default)
        XCTAssertFalse(excessive.isValid)
        XCTAssertTrue(excessive.reasons.contains(.phoneMovementExcessive))

        input.phoneStability = .minor
        let minor = SampleValidator.validate(input, config: .default)
        XCTAssertTrue(minor.isValid)
        XCTAssertEqual(minor.confidence, 0.85, accuracy: 1e-9)
        XCTAssertTrue(minor.reasons.contains(.phoneMovementMinor))
    }

    func testHeadVelocity() {
        var input = healthyInput()
        input.headAngularVelocityDegPerSec = 130    // above 120 °/s
        XCTAssertFalse(SampleValidator.validate(input, config: .default).isValid)

        input.headAngularVelocityDegPerSec = 100    // above 0.8 * 120 = 96
        let fast = SampleValidator.validate(input, config: .default)
        XCTAssertTrue(fast.isValid)
        XCTAssertEqual(fast.confidence, 0.9, accuracy: 1e-9)
    }

    func testNonMonotonicTimestampAndInterruptionReject() {
        var input = healthyInput()
        input.timestampMonotonic = false
        XCTAssertTrue(SampleValidator.validate(input, config: .default)
            .reasons.contains(.nonMonotonicTimestamp))

        var interrupted = healthyInput()
        interrupted.interrupted = true
        XCTAssertTrue(SampleValidator.validate(interrupted, config: .default)
            .reasons.contains(.sessionInterrupted))
    }

    func testDepthIssuesDownWeightButDoNotReject() {
        var input = healthyInput()
        input.depthAvailable = false
        input.depthValidPixelCount = nil
        input.depthValidPixelRatio = nil
        input.depthConsistent = nil
        let unavailable = SampleValidator.validate(input, config: .default)
        XCTAssertTrue(unavailable.isValid)
        XCTAssertEqual(unavailable.confidence, 0.9, accuracy: 1e-9)
        XCTAssertTrue(unavailable.reasons.contains(.depthUnavailable))

        var sparse = healthyInput()
        sparse.depthValidPixelCount = 5
        sparse.depthValidPixelRatio = 0.05
        let sparseResult = SampleValidator.validate(sparse, config: .default)
        XCTAssertTrue(sparseResult.isValid)
        XCTAssertTrue(sparseResult.reasons.contains(.insufficientDepthPixels))

        var inconsistent = healthyInput()
        inconsistent.depthConsistent = false
        let inconsistentResult = SampleValidator.validate(inconsistent, config: .default)
        XCTAssertTrue(inconsistentResult.isValid)
        XCTAssertEqual(inconsistentResult.confidence, 0.85, accuracy: 1e-9)
        XCTAssertTrue(inconsistentResult.reasons.contains(.depthInconsistent))
    }

    func testConfidencePenaltiesAccumulate() {
        var input = healthyInput()
        input.phoneStability = .minor               // -0.15
        input.depthAvailable = false                // -0.10
        input.distanceDeviationMeters = 0.03        // -0.20
        input.headAngularVelocityDegPerSec = 100    // -0.10
        let result = SampleValidator.validate(input, config: .default)
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.confidence, 0.45, accuracy: 1e-9)
    }

    func testConfidenceHasFloor() {
        var input = healthyInput()
        input.phoneStability = .minor
        input.depthAvailable = false
        input.depthConsistent = nil
        input.depthValidPixelCount = nil
        input.depthValidPixelRatio = nil
        input.distanceDeviationMeters = 0.03
        input.headAngularVelocityDegPerSec = 100
        // Penalties: 0.15 + 0.10 + 0.20 + 0.10 = 0.55 -> 0.45; floor is 0.05.
        let result = SampleValidator.validate(input, config: .default)
        XCTAssertGreaterThanOrEqual(result.confidence, 0.05)
    }
}
