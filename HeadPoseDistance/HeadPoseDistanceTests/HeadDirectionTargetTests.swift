import XCTest
@testable import HeadPoseDistance

/// Head-direction target geometry and the on-target decision that drives the
/// guidance UI. Convention under test: yaw > 0 = head turned right,
/// pitch > 0 = head rotated up.
final class HeadDirectionTargetTests: XCTestCase {

    private var config = MeasurementConfig.default

    // MARK: - Target vectors

    func testCardinalTargetsPointTheRightWay() {
        XCTAssertEqual(HeadDirectionTarget.target(for: .up),
                       HeadDirectionTarget(yawUnit: 0, pitchUnit: 1))
        XCTAssertEqual(HeadDirectionTarget.target(for: .down),
                       HeadDirectionTarget(yawUnit: 0, pitchUnit: -1))
        XCTAssertEqual(HeadDirectionTarget.target(for: .left),
                       HeadDirectionTarget(yawUnit: -1, pitchUnit: 0))
        XCTAssertEqual(HeadDirectionTarget.target(for: .right),
                       HeadDirectionTarget(yawUnit: 1, pitchUnit: 0))
    }

    func testDiagonalTargetsAreUnitVectors() {
        let diagonals: [ProtocolPhase] = [.upperLeft, .upperRight, .lowerLeft, .lowerRight]
        for phase in diagonals {
            let target = try! XCTUnwrap(HeadDirectionTarget.target(for: phase))
            let magnitude = (target.yawUnit * target.yawUnit
                             + target.pitchUnit * target.pitchUnit).squareRoot()
            XCTAssertEqual(magnitude, 1.0, accuracy: 1e-9,
                           "\(phase) target must be a unit vector")
        }
    }

    func testDiagonalQuadrantSigns() {
        let upperRight = try! XCTUnwrap(HeadDirectionTarget.target(for: .upperRight))
        XCTAssertGreaterThan(upperRight.yawUnit, 0)
        XCTAssertGreaterThan(upperRight.pitchUnit, 0)

        let lowerLeft = try! XCTUnwrap(HeadDirectionTarget.target(for: .lowerLeft))
        XCTAssertLessThan(lowerLeft.yawUnit, 0)
        XCTAssertLessThan(lowerLeft.pitchUnit, 0)
    }

    func testNonDirectionalPhasesHaveNoTarget() {
        XCTAssertNil(HeadDirectionTarget.target(for: .idle))
        XCTAssertNil(HeadDirectionTarget.target(for: .neutralCapture))
        XCTAssertNil(HeadDirectionTarget.target(for: .complete))
        XCTAssertTrue(try XCTUnwrap(HeadDirectionTarget.target(for: .center)).isCenter)
    }

    // MARK: - Projection math

    func testAchievedDegreesProjectsOntoTargetAxis() {
        let right = try! XCTUnwrap(HeadDirectionTarget.target(for: .right))
        XCTAssertEqual(right.achievedDegrees(yawDegrees: 25, pitchDegrees: 3), 25, accuracy: 1e-9)
        // Turning the wrong way registers as negative progress.
        XCTAssertEqual(right.achievedDegrees(yawDegrees: -25, pitchDegrees: 0), -25, accuracy: 1e-9)
    }

    func testOffAxisIsPerpendicularComponent() {
        let up = try! XCTUnwrap(HeadDirectionTarget.target(for: .up))
        // Pure pitch is perfectly on-axis for the "up" target.
        XCTAssertEqual(up.offAxisDegrees(yawDegrees: 0, pitchDegrees: 30), 0, accuracy: 1e-9)
        // Yaw drift while looking up is entirely off-axis.
        XCTAssertEqual(up.offAxisDegrees(yawDegrees: 14, pitchDegrees: 30), 14, accuracy: 1e-9)
    }

    func testDiagonalProjectionSplitsEvenly() {
        let upperRight = try! XCTUnwrap(HeadDirectionTarget.target(for: .upperRight))
        // Equal yaw and pitch is exactly along the diagonal: magnitude = √2 · 20.
        let achieved = upperRight.achievedDegrees(yawDegrees: 20, pitchDegrees: 20)
        XCTAssertEqual(achieved, 20 * 2.0.squareRoot(), accuracy: 1e-9)
        XCTAssertEqual(upperRight.offAxisDegrees(yawDegrees: 20, pitchDegrees: 20),
                       0, accuracy: 1e-9)
    }

    // MARK: - Progress evaluation

    func testReachingTargetAngleMarksOnTarget() {
        let progress = HeadDirectionProgress.evaluate(
            phase: .right,
            yawDegrees: config.targetAngleDegrees,
            pitchDegrees: 0,
            config: config)
        XCTAssertTrue(progress.isOnTarget)
        XCTAssertEqual(progress.fraction, 1.0, accuracy: 1e-9)
        XCTAssertFalse(progress.isOffAxis)
    }

    func testShortOfTargetIsNotOnTarget() {
        let progress = HeadDirectionProgress.evaluate(
            phase: .right,
            yawDegrees: config.targetAngleDegrees / 2,
            pitchDegrees: 0,
            config: config)
        XCTAssertFalse(progress.isOnTarget)
        XCTAssertEqual(progress.fraction, 0.5, accuracy: 1e-9)
    }

    func testTurningTheWrongWayGivesZeroFraction() {
        let progress = HeadDirectionProgress.evaluate(
            phase: .right,
            yawDegrees: -30,
            pitchDegrees: 0,
            config: config)
        XCTAssertFalse(progress.isOnTarget)
        XCTAssertEqual(progress.fraction, 0, accuracy: 1e-9)
        XCTAssertLessThan(progress.achievedDegrees, 0)
    }

    func testExcessiveOffAxisBlocksOnTarget() {
        let progress = HeadDirectionProgress.evaluate(
            phase: .up,
            yawDegrees: config.maxOffAxisDegrees + 5,
            pitchDegrees: config.targetAngleDegrees + 5,
            config: config)
        XCTAssertFalse(progress.isOnTarget, "off-axis drift must block completion")
        XCTAssertTrue(progress.isOffAxis)
    }

    /// Jitter around neutral shouldn't flash an off-axis warning before the
    /// participant has meaningfully started moving.
    func testOffAxisWarningSuppressedNearNeutral() {
        let progress = HeadDirectionProgress.evaluate(
            phase: .up,
            yawDegrees: config.maxOffAxisDegrees + 5,
            pitchDegrees: 1,
            config: config)
        XCTAssertFalse(progress.isOffAxis)
    }

    func testCenterPhaseUsesDeviationFromNeutral() {
        let centered = HeadDirectionProgress.evaluate(
            phase: .center, yawDegrees: 1, pitchDegrees: 1, config: config)
        XCTAssertTrue(centered.isOnTarget)

        let offCenter = HeadDirectionProgress.evaluate(
            phase: .center, yawDegrees: 20, pitchDegrees: 0, config: config)
        XCTAssertFalse(offCenter.isOnTarget)
        XCTAssertEqual(offCenter.achievedDegrees, 20, accuracy: 1e-9)
    }

    func testCenterFractionRisesAsUserRecenters() {
        let far = HeadDirectionProgress.evaluate(
            phase: .center, yawDegrees: 15, pitchDegrees: 0, config: config)
        let near = HeadDirectionProgress.evaluate(
            phase: .center, yawDegrees: 3, pitchDegrees: 0, config: config)
        XCTAssertGreaterThan(near.fraction, far.fraction)
    }

    // MARK: - Degenerate input

    func testMissingOrNonFiniteAnglesYieldNoProgress() {
        XCTAssertEqual(HeadDirectionProgress.evaluate(
            phase: .up, yawDegrees: nil, pitchDegrees: 10, config: config), .none)
        XCTAssertEqual(HeadDirectionProgress.evaluate(
            phase: .up, yawDegrees: .nan, pitchDegrees: 10, config: config), .none)
        XCTAssertEqual(HeadDirectionProgress.evaluate(
            phase: .up, yawDegrees: 0, pitchDegrees: .infinity, config: config), .none)
    }

    func testPhaseWithoutTargetYieldsNoProgress() {
        XCTAssertEqual(HeadDirectionProgress.evaluate(
            phase: .complete, yawDegrees: 30, pitchDegrees: 30, config: config), .none)
    }

    func testFractionIsClampedToUnitRange() {
        let progress = HeadDirectionProgress.evaluate(
            phase: .right, yawDegrees: 500, pitchDegrees: 0, config: config)
        XCTAssertEqual(progress.fraction, 1.0, accuracy: 1e-9)
    }
}
