import XCTest
@testable import HeadPoseDistance

/// Tests for the free-exploration state machine.
///
/// Core invariant, shared with the eight-spoke protocol: completion is earned
/// by the measured pose, never by elapsed time. Here that means the session
/// ends only when the coverage grid is genuinely filled.
final class FreeExplorationControllerTests: XCTestCase {

    private var config: MeasurementConfig = {
        var c = MeasurementConfig.default
        // Small dwell requirement keeps the tests fast; grid shape unchanged.
        c.coverageSamplesPerCell = 3
        c.explorationInstructionSeconds = 1.0
        return c
    }()

    private let step = 1.0 / 30.0

    // MARK: - Helpers

    @discardableResult
    private func feed(_ controller: FreeExplorationController,
                      from start: TimeInterval,
                      duration: TimeInterval,
                      yaw: Double = 0, pitch: Double = 0,
                      velocity: Double = 5,
                      tracked: Bool = true,
                      deviation: Double = 0,
                      lateralInBounds: Bool = true,
                      stability: PhoneStability = .stable) -> ProtocolGuidanceOutput {
        var output: ProtocolGuidanceOutput!
        var t = start
        while t <= start + duration {
            output = controller.update(.init(timestamp: t,
                                             faceTracked: tracked,
                                             yawDegrees: yaw,
                                             pitchDegrees: pitch,
                                             angularVelocityDegPerSec: velocity,
                                             distanceDeviationMeters: deviation,
                                             lateralInBounds: lateralInBounds,
                                             phoneStability: stability))
            t += step
        }
        return output
    }

    /// Drives past the initial neutral hold so exploration is running.
    @discardableResult
    private func startExploring(_ controller: FreeExplorationController,
                                from start: TimeInterval = 0) -> TimeInterval {
        let duration = config.neutralHoldSeconds + 0.5
        feed(controller, from: start, duration: duration, yaw: 0, pitch: 0)
        XCTAssertEqual(controller.state, .exploring)
        return start + duration + step
    }

    /// Visits every required cell enough times to cover it. Returns the time
    /// cursor after the sweep.
    @discardableResult
    private func coverWholeField(_ controller: FreeExplorationController,
                                 from start: TimeInterval) -> TimeInterval {
        let grid = CoverageGrid(config: config)
        var t = start
        for row in 0..<grid.rows {
            for column in 0..<grid.columns where grid.isRequired(column: column, row: row) {
                let centre = grid.cellCenter(column: column, row: row)
                let yaw = centre.u * config.coverageYawAmplitudeDegrees
                let pitch = centre.v * config.coveragePitchAmplitudeDegrees
                for _ in 0..<(config.coverageSamplesPerCell + 1) {
                    _ = controller.update(.init(timestamp: t,
                                                faceTracked: true,
                                                yawDegrees: yaw,
                                                pitchDegrees: pitch,
                                                angularVelocityDegPerSec: 5,
                                                distanceDeviationMeters: 0,
                                                lateralInBounds: true,
                                                phoneStability: .stable))
                    t += step
                }
            }
        }
        return t
    }

    // MARK: - Entry

    func testExplorationDoesNotStartUntilNeutralIsHeld() {
        let controller = FreeExplorationController(config: config)
        let output = feed(controller, from: 0, duration: 3.0, yaw: 18, pitch: 12)
        XCTAssertEqual(controller.state, .returningToNeutral)
        XCTAssertEqual(controller.grid.coveredRequiredCellCount, 0)
        XCTAssertNil(output.coverage?.currentColumn,
                     "no cell should be reported before exploration starts")
        XCTAssertEqual(output.protocolPhase, .center)
    }

    func testExplorationStartsAfterNeutralHold() {
        let controller = FreeExplorationController(config: config)
        startExploring(controller)
        XCTAssertTrue(controller.transitions.contains { $0.reason == "exploration_started" })
    }

    // MARK: - The central invariant

    /// Sitting still at neutral covers exactly one cell and never finishes,
    /// however long it runs. Coverage is earned, not waited out.
    func testStationaryHeadNeverCompletes() {
        let controller = FreeExplorationController(config: config)
        let t = startExploring(controller)
        feed(controller, from: t, duration: 60, yaw: 0, pitch: 0)

        XCTAssertEqual(controller.state, .exploring)
        XCTAssertEqual(controller.grid.coveredRequiredCellCount, 1)
        XCTAssertFalse(controller.coverageComplete)
    }

    /// Samples above the slow-movement limit are not counted, so a participant
    /// cannot fill the grid by thrashing.
    func testFastMovementDoesNotAccrueCoverage() {
        let controller = FreeExplorationController(config: config)
        let t = startExploring(controller)
        // Settling at neutral legitimately covers the centre cell, so measure
        // growth from there rather than from zero.
        let baseline = controller.grid.coveredRequiredCellCount
        let output = feed(controller, from: t, duration: 2.0, yaw: 10, pitch: 5,
                          velocity: config.guidedMaxAngularVelocityDegPerSec + 20)

        XCTAssertEqual(controller.grid.coveredRequiredCellCount, baseline,
                       "samples above the speed limit must not count")
        XCTAssertEqual(output.feedback, .tooFast,
                       "the participant has to be told why coverage stopped growing")
    }

    func testVisitingCellsAccruesCoverageAndReportsTheCurrentCell() {
        let controller = FreeExplorationController(config: config)
        let t = startExploring(controller)
        let output = feed(controller, from: t, duration: 1.0,
                          yaw: config.coverageYawAmplitudeDegrees * 0.8, pitch: 0)

        XCTAssertEqual(output.protocolPhase, .explore)
        XCTAssertEqual(output.coverage?.currentRow, 4)
        XCTAssertEqual(output.coverage?.currentColumn, 9)
        XCTAssertTrue(controller.grid.isCovered(column: 9, row: 4),
                      "the visited cell specifically must be covered")
        XCTAssertGreaterThan(output.coverage?.coveredFraction ?? 0, 0)
    }

    // MARK: - Completion

    func testCoveringTheFieldThenReturningToNeutralCompletes() {
        let controller = FreeExplorationController(config: config)
        var cursor = startExploring(controller)
        cursor = coverWholeField(controller, from: cursor)

        XCTAssertTrue(controller.coverageComplete)
        XCTAssertTrue(controller.transitions.contains { $0.reason == "coverage_complete" })

        let output = feed(controller, from: cursor,
                          duration: config.neutralHoldSeconds + 0.5, yaw: 0, pitch: 0)
        XCTAssertEqual(controller.state, .complete)
        XCTAssertTrue(output.isComplete)
        XCTAssertEqual(output.protocolPhase, .complete)
        XCTAssertTrue(controller.transitions.contains { $0.reason == "all_stages_complete" })
    }

    /// Completion fires at the configured threshold, not only at a perfect
    /// 100% — the most extreme cells are unreachable for some people.
    func testCompletionThresholdIsBelowFullCoverage() {
        XCTAssertLessThan(config.coverageCompletionFraction, 1.0)
        XCTAssertGreaterThan(config.coverageCompletionFraction, 0.8)
    }

    // MARK: - Pauses

    func testTrackingLossPausesAndStopsCoverage() {
        let controller = FreeExplorationController(config: config)
        let t = startExploring(controller)
        feed(controller, from: t, duration: 0.5, yaw: 8, pitch: 4)
        let covered = controller.grid.coveredRequiredCellCount

        let cursor = t + 0.5 + step
        feed(controller, from: cursor, duration: 1.0, yaw: 12, pitch: 6, tracked: false)
        XCTAssertEqual(controller.state, .pausedForTracking)
        XCTAssertEqual(controller.grid.coveredRequiredCellCount, covered)

        feed(controller, from: cursor + 1.0 + step, duration: 0.3, yaw: 8, pitch: 4)
        XCTAssertEqual(controller.state, .exploring)
    }

    func testExcessivePhoneMotionPauses() {
        let controller = FreeExplorationController(config: config)
        let t = startExploring(controller)
        feed(controller, from: t, duration: 0.3, stability: .excessive)
        XCTAssertEqual(controller.state, .pausedForPhoneMotion)
    }

    func testDistanceDriftPauses() {
        let controller = FreeExplorationController(config: config)
        let t = startExploring(controller)
        feed(controller, from: t, duration: config.distancePauseEnterSeconds + 0.4,
             yaw: 0, pitch: 0, deviation: config.guidedDistanceBandMeters + 0.02)
        XCTAssertEqual(controller.state, .pausedForDistance)
    }

    func testLateralDriftPauses() {
        let controller = FreeExplorationController(config: config)
        let t = startExploring(controller)
        feed(controller, from: t, duration: config.distancePauseEnterSeconds + 0.4,
             yaw: 0, pitch: 0, lateralInBounds: false)
        XCTAssertEqual(controller.state, .pausedForDistance)
    }

    /// A pause mid-exploration must keep labelling samples `explore`, not
    /// `center` — otherwise paused frames get misfiled into the neutral cluster.
    func testPausedMidExplorationStillLabelsSamplesAsExplore() {
        let controller = FreeExplorationController(config: config)
        let t = startExploring(controller)
        feed(controller, from: t, duration: 0.3, yaw: 8, pitch: 4)
        let output = feed(controller, from: t + 0.3 + step, duration: 0.5, tracked: false)
        XCTAssertEqual(output.protocolPhase, .explore)
    }

    // MARK: - Instruction wording

    /// The caption must describe the physical action in body terms. "Circle
    /// your nose" is what finally made the task legible; abstract references to
    /// matching or following a target did not.
    func testCaptionDescribesThePhysicalAction() {
        let controller = FreeExplorationController(config: config)
        let t = startExploring(controller)
        let output = feed(controller, from: t, duration: 0.2, yaw: 2, pitch: 1)

        let instruction = output.instruction.lowercased()
        XCTAssertFalse(instruction.isEmpty)
        XCTAssertTrue(instruction.contains("nose") || instruction.contains("head"),
                      "caption must name a body part, got: \(output.instruction)")
        XCTAssertFalse(instruction.contains("follow"),
                       "'follow' invites gaze tracking, got: \(output.instruction)")
        XCTAssertFalse(instruction.contains("outline"),
                       "there is no outline to match any more, got: \(output.instruction)")
    }

    /// The caption sits below the fixation dot, so reading it breaks fixation.
    /// It must retire once the participant is oriented.
    func testCaptionRetiresAfterItsWindow() {
        let controller = FreeExplorationController(config: config)
        let t = startExploring(controller)
        let early = feed(controller, from: t, duration: 0.2, yaw: 2, pitch: 1)
        XCTAssertFalse(early.instruction.isEmpty)

        let late = feed(controller, from: t + 0.2 + step,
                        duration: config.explorationInstructionSeconds + 0.5,
                        yaw: 2, pitch: 1)
        XCTAssertEqual(controller.state, .exploring)
        XCTAssertTrue(late.instruction.isEmpty,
                      "caption should retire, got: \(late.instruction)")
    }

    // MARK: - Transition log

    func testTransitionsAreRecordedWithReasons() {
        let controller = FreeExplorationController(config: config)
        let t = startExploring(controller)
        feed(controller, from: t, duration: 0.3, yaw: 5, pitch: 2)

        XCTAssertFalse(controller.transitions.isEmpty)
        XCTAssertEqual(controller.transitions.first?.reason, "recording_started")
        for transition in controller.transitions {
            XCTAssertFalse(transition.reason.isEmpty)
            XCTAssertFalse(transition.toState.isEmpty)
            XCTAssertTrue(transition.sessionElapsedSeconds >= 0)
        }
    }

    // MARK: - Timestamp gaps

    /// Backgrounding produces a large timestamp jump; it must not fabricate
    /// coverage or credit the neutral hold.
    func testLargeUpdateGapDoesNotFabricateCoverage() {
        let controller = FreeExplorationController(config: config)
        let t = startExploring(controller)
        feed(controller, from: t, duration: 0.3, yaw: 8, pitch: 4)
        let covered = controller.grid.coveredRequiredCellCount

        _ = controller.update(.init(timestamp: t + 0.3 + 30,
                                    faceTracked: true,
                                    yawDegrees: 8, pitchDegrees: 4,
                                    angularVelocityDegPerSec: 5,
                                    distanceDeviationMeters: 0,
                                    lateralInBounds: true,
                                    phoneStability: .stable))
        // One frame may legitimately add one sample, but never a burst of them.
        XCTAssertLessThanOrEqual(controller.grid.coveredRequiredCellCount, covered + 1)
    }
}
