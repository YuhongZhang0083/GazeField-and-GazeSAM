import XCTest
@testable import HeadPoseDistance

/// Regression tests for the pose-driven guided-movement state machine.
/// The core invariant throughout: stages advance because the measured pose
/// satisfied the stage's criteria — NEVER because time passed.
final class GuidedMovementControllerTests: XCTestCase {

    private var config = MeasurementConfig.default

    // MARK: - Helpers

    /// Feeds a constant pose for `duration` seconds at ~30 Hz and returns the
    /// last output.
    @discardableResult
    private func feed(_ controller: GuidedMovementController,
                      from start: TimeInterval,
                      duration: TimeInterval,
                      yaw: Double = 0, pitch: Double = 0,
                      velocity: Double = 5,
                      tracked: Bool = true,
                      deviation: Double = 0,
                      lateralInBounds: Bool = true,
                      stability: PhoneStability = .stable)
        -> GuidedMovementController.GuidanceOutput {
        var output: GuidedMovementController.GuidanceOutput!
        var t = start
        let step = 1.0 / 30.0
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

    /// Drives the controller through the initial center verification so the
    /// first directional stage (up) is active. Returns the time cursor.
    private func passInitialCenter(_ controller: GuidedMovementController)
        -> TimeInterval {
        feed(controller, from: 0, duration: config.neutralHoldSeconds + 0.3)
        return config.neutralHoldSeconds + 0.4
    }

    /// Completes the currently active directional stage (assumed `.up`-like
    /// with the given target pose) including the return to neutral.
    private func completeStage(_ controller: GuidedMovementController,
                               from start: TimeInterval,
                               yaw: Double, pitch: Double) -> TimeInterval {
        var t = start
        // Move to and hold the target.
        feed(controller, from: t, duration: config.targetHoldSeconds + 0.3,
             yaw: yaw, pitch: pitch)
        t += config.targetHoldSeconds + 0.4
        // Return to and hold neutral.
        feed(controller, from: t, duration: config.neutralHoldSeconds + 0.3)
        t += config.neutralHoldSeconds + 0.4
        return t
    }

    private func pose(for phase: ProtocolPhase, degrees: Double) -> (yaw: Double, pitch: Double) {
        let target = HeadDirectionTarget.target(for: phase)!
        return (target.yawUnit * degrees, target.pitchUnit * degrees)
    }

    // MARK: - 1. No time-based advancement

    func testStageDoesNotAdvanceOnElapsedTimeAlone() {
        let controller = GuidedMovementController(config: config)
        var t = passInitialCenter(controller)

        // Sit at neutral doing nothing for far longer than the legacy
        // schedule would ever have waited (but below the retry timeout).
        let output = feed(controller, from: t, duration: 20)
        t += 20

        XCTAssertEqual(output.stageIndex, 0, "must still be on the first stage")
        XCTAssertEqual(output.direction, .up)
        XCTAssertTrue(output.completedDirections.isEmpty,
                      "nothing may complete without the pose reaching the target")
        XCTAssertFalse(output.isComplete)
    }

    func testHoldIsNotCreditedWhileAwayFromTarget() {
        let controller = GuidedMovementController(config: config)
        var t = passInitialCenter(controller)

        // Hover just below the target angle for a long time.
        let nearly = config.targetAngleDegrees - 2
        let output = feed(controller, from: t, duration: 10, pitch: nearly)
        t += 10

        XCTAssertNotEqual(output.state, .holdingTargetPose)
        XCTAssertTrue(output.completedDirections.isEmpty)
    }

    // MARK: - 2/10. Direction detection (cardinal + diagonal)

    func testCorrectDirectionMovesToHolding() {
        let controller = GuidedMovementController(config: config)
        let t = passInitialCenter(controller)

        let output = feed(controller, from: t, duration: 0.2,
                          pitch: config.targetAngleDegrees + 2)
        XCTAssertEqual(output.state, .holdingTargetPose)
    }

    func testDiagonalStageRequiresBothAxes() {
        let controller = GuidedMovementController(config: config)
        var t = passInitialCenter(controller)

        // Complete the four cardinal stages to reach upper-left.
        for phase in [ProtocolPhase.up, .down, .left, .right] {
            let p = pose(for: phase, degrees: config.targetAngleDegrees + 4)
            t = completeStage(controller, from: t, yaw: p.yaw, pitch: p.pitch)
        }

        // Pure pitch (no yaw) must NOT satisfy upper-left...
        let wrongOutput = feed(controller, from: t, duration: 1.0,
                               pitch: config.targetAngleDegrees + 4)
        t += 1.1
        XCTAssertEqual(wrongOutput.direction, .upperLeft)
        XCTAssertNotEqual(wrongOutput.state, .holdingTargetPose,
                          "pure pitch may not satisfy a diagonal stage")

        // ...but a genuine diagonal does.
        let p = pose(for: .upperLeft, degrees: config.targetAngleDegrees + 4)
        let diagonalOutput = feed(controller, from: t, duration: 0.2,
                                  yaw: p.yaw, pitch: p.pitch)
        XCTAssertEqual(diagonalOutput.state, .holdingTargetPose)
    }

    // MARK: - 3. Wrong-direction feedback

    func testWrongDirectionProducesCorrectiveFeedback() {
        let controller = GuidedMovementController(config: config)
        let t = passInitialCenter(controller)

        // Stage is "up"; move well down instead.
        let output = feed(controller, from: t, duration: 0.3,
                          pitch: -(config.wrongDirectionThresholdDegrees + 4))
        XCTAssertEqual(output.feedback, .wrongDirection)
        XCTAssertTrue(output.completedDirections.isEmpty)
    }

    func testTooFastProducesSlowDownFeedback() {
        let controller = GuidedMovementController(config: config)
        let t = passInitialCenter(controller)

        let output = feed(controller, from: t, duration: 0.3,
                          pitch: 10,
                          velocity: config.guidedMaxAngularVelocityDegPerSec + 20)
        XCTAssertEqual(output.feedback, .tooFast)
    }

    // MARK: - 4. Hold requirement

    func testTargetMustBeHeldForConfiguredDuration() {
        let controller = GuidedMovementController(config: config)
        var t = passInitialCenter(controller)

        // Reach the target but leave before the hold completes.
        feed(controller, from: t, duration: config.targetHoldSeconds * 0.5,
             pitch: config.targetAngleDegrees + 2)
        t += config.targetHoldSeconds * 0.5 + 1.0 / 30

        let broken = feed(controller, from: t, duration: 0.2, pitch: 2)
        t += 0.3
        XCTAssertTrue(broken.completedDirections.isEmpty,
                      "leaving the target zone early must not complete the stage")

        // Now reach it again and hold long enough.
        let held = feed(controller, from: t,
                        duration: config.targetHoldSeconds + 0.3,
                        pitch: config.targetAngleDegrees + 2)
        XCTAssertTrue(held.completedDirections.contains(.up))
    }

    // MARK: - 5. Return-to-neutral requirement

    func testNextStageRequiresReturnToNeutral() {
        let controller = GuidedMovementController(config: config)
        var t = passInitialCenter(controller)

        // Complete the "up" hold.
        feed(controller, from: t, duration: config.targetHoldSeconds + 0.3,
             pitch: config.targetAngleDegrees + 2)
        t += config.targetHoldSeconds + 0.4

        // Stay up — the next stage must NOT begin.
        let stillUp = feed(controller, from: t, duration: 3,
                           pitch: config.targetAngleDegrees + 2)
        t += 3.1
        XCTAssertEqual(stillUp.state, .returningToNeutral)
        XCTAssertEqual(stillUp.direction, .up, "stage index must not advance")

        // Return to neutral and hold — now the next stage begins.
        let next = feed(controller, from: t,
                        duration: config.neutralHoldSeconds + 0.3)
        XCTAssertEqual(next.direction, .down)
        XCTAssertEqual(next.state, .instructingDirection)
    }

    // MARK: - 6/9. Distance pause + hysteresis

    func testDistanceInvalidPausesAndRecovers() {
        let controller = GuidedMovementController(config: config)
        var t = passInitialCenter(controller)

        // Go out of range long enough to trip the pause.
        let out = feed(controller, from: t,
                       duration: config.distancePauseEnterSeconds + 0.3,
                       deviation: config.guidedDistanceBandMeters + 0.05)
        t += config.distancePauseEnterSeconds + 0.4
        XCTAssertEqual(out.state, .pausedForDistance)
        XCTAssertTrue(out.isPaused)
        XCTAssertEqual(out.instruction, "Move closer")

        // Come back within the exit band for the exit dwell.
        let back = feed(controller, from: t,
                        duration: config.distancePauseExitSeconds + 0.3,
                        deviation: 0)
        XCTAssertFalse(back.isPaused, "must resume after recovery dwell")
    }

    func testDistanceHysteresisIgnoresBriefBlips() {
        let controller = GuidedMovementController(config: config)
        var t = passInitialCenter(controller)

        // A blip shorter than the enter dwell must not pause.
        let blip = feed(controller, from: t,
                        duration: config.distancePauseEnterSeconds * 0.4,
                        deviation: config.guidedDistanceBandMeters + 0.05)
        t += config.distancePauseEnterSeconds * 0.4 + 1.0 / 30
        XCTAssertFalse(blip.isPaused)

        // Between the exit band and the enter band: must not re-trigger
        // (hysteresis gap) once recovered.
        let between = (config.guidedDistanceExitBandMeters
                       + config.guidedDistanceBandMeters) / 2
        let inGap = feed(controller, from: t, duration: 2, deviation: between)
        XCTAssertFalse(inGap.isPaused,
                       "deviation inside the hysteresis gap must not pause")
    }

    func testLateralOutOfBoundsPausesAndRecovers() {
        let controller = GuidedMovementController(config: config)
        var t = passInitialCenter(controller)

        // Distance fine, but the face slid outside the fixed lateral bounds.
        let out = feed(controller, from: t,
                       duration: config.distancePauseEnterSeconds + 0.3,
                       deviation: 0, lateralInBounds: false)
        t += config.distancePauseEnterSeconds + 0.4
        XCTAssertEqual(out.state, .pausedForDistance)
        XCTAssertEqual(out.instruction, "Recenter your face",
                       "lateral pause shows the generic recenter text")

        // Even a perfect target angle must not complete while out of bounds.
        let stillOut = feed(controller, from: t, duration: 2,
                            pitch: config.targetAngleDegrees + 5,
                            lateralInBounds: false)
        t += 2.1
        XCTAssertTrue(stillOut.completedDirections.isEmpty)

        // Return into bounds → resume.
        let back = feed(controller, from: t,
                        duration: config.distancePauseExitSeconds + 0.3,
                        lateralInBounds: true)
        XCTAssertFalse(back.isPaused)
    }

    // MARK: - 7. Tracking pause

    func testTrackingLossPausesProgression() {
        let controller = GuidedMovementController(config: config)
        var t = passInitialCenter(controller)

        let lost = feed(controller, from: t, duration: 0.5, tracked: false)
        t += 0.6
        XCTAssertEqual(lost.state, .pausedForTracking)

        // While untracked, even a perfect pose must not progress.
        let stillLost = feed(controller, from: t, duration: 2,
                             pitch: config.targetAngleDegrees + 5, tracked: false)
        t += 2.1
        XCTAssertTrue(stillLost.completedDirections.isEmpty)

        let recovered = feed(controller, from: t, duration: 0.2)
        XCTAssertFalse(recovered.isPaused)
    }

    // MARK: - 8. Phone-motion pause

    func testExcessivePhoneMotionPausesProgression() {
        let controller = GuidedMovementController(config: config)
        var t = passInitialCenter(controller)

        let moving = feed(controller, from: t, duration: 0.5,
                          stability: .excessive)
        t += 0.6
        XCTAssertEqual(moving.state, .pausedForPhoneMotion)
        XCTAssertEqual(moving.instruction, "Phone moved — hold it still")

        let calm = feed(controller, from: t, duration: 0.2)
        XCTAssertFalse(calm.isPaused)
    }

    func testPauseDemotesInProgressHold() {
        let controller = GuidedMovementController(config: config)
        var t = passInitialCenter(controller)

        // Get into the hold, then lose tracking mid-hold.
        feed(controller, from: t, duration: config.targetHoldSeconds * 0.5,
             pitch: config.targetAngleDegrees + 2)
        t += config.targetHoldSeconds * 0.5 + 1.0 / 30
        feed(controller, from: t, duration: 0.3, tracked: false)
        t += 0.4

        // On recovery the hold must restart from zero, not resume mid-way.
        let resumed = feed(controller, from: t,
                           duration: config.targetHoldSeconds * 0.6,
                           yaw: 0, pitch: config.targetAngleDegrees + 2)
        XCTAssertTrue(resumed.completedDirections.isEmpty,
                      "paused time must not count toward the hold")
    }

    // MARK: - 11. Transition reasons

    func testTransitionsRecordReasons() {
        let controller = GuidedMovementController(config: config)
        var t = passInitialCenter(controller)
        t = completeStage(controller, from: t,
                          yaw: 0, pitch: config.targetAngleDegrees + 2)

        let reasons = controller.transitions.map(\.reason)
        XCTAssertTrue(reasons.contains("recording_started"))
        XCTAssertTrue(reasons.contains("neutral_hold_completed"))
        XCTAssertTrue(reasons.contains("target_reached"))
        XCTAssertTrue(reasons.contains("hold_completed"))
        XCTAssertTrue(reasons.contains("reached_neutral"))

        // Every transition carries a stage phase label and a timestamp.
        for transition in controller.transitions {
            XCTAssertFalse(transition.stagePhase.isEmpty)
            XCTAssertGreaterThanOrEqual(transition.sessionElapsedSeconds, 0)
        }
    }

    // MARK: - 12. Completion

    func testCompletionOnlyAfterAllEightStages() {
        let controller = GuidedMovementController(config: config)
        var t = passInitialCenter(controller)

        for (index, phase) in GuidedMovementController.directionSequence.enumerated() {
            let p = pose(for: phase, degrees: config.targetAngleDegrees + 4)
            let before = controller.transitions.count
            t = completeStage(controller, from: t, yaw: p.yaw, pitch: p.pitch)
            XCTAssertGreaterThan(controller.transitions.count, before)

            let output = feed(controller, from: t, duration: 1.0 / 30)
            t += 0.1
            if index < GuidedMovementController.directionSequence.count - 1 {
                XCTAssertFalse(output.isComplete,
                               "must not complete after only \(index + 1) stages")
            } else {
                XCTAssertTrue(output.isComplete)
                XCTAssertEqual(output.protocolPhase, .complete)
            }
        }

        XCTAssertEqual(controller.completedDirections,
                       Set(GuidedMovementController.directionSequence))
        XCTAssertTrue(controller.transitions.map(\.reason)
            .contains("all_stages_complete"))
    }

    // MARK: - 13. Timeout is retry, never success

    func testTimeoutRetriesInsteadOfAdvancing() {
        var quickConfig = config
        quickConfig.stageTimeoutSeconds = 2.0
        let controller = GuidedMovementController(config: quickConfig)
        var t = passInitialCenter(controller)

        // Do nothing until well past the timeout.
        let output = feed(controller, from: t, duration: 3.5)
        t += 3.6

        XCTAssertTrue(controller.transitions.map(\.reason).contains("stage_timeout"))
        XCTAssertGreaterThanOrEqual(controller.retryCount, 1)
        XCTAssertTrue(output.completedDirections.isEmpty,
                      "timeout must never count as success")
        XCTAssertEqual(output.direction, .up, "stage must be retried, not skipped")
        XCTAssertFalse(output.isComplete)
    }

    // MARK: - Sample labeling

    func testProtocolPhaseLabelsMatchStageActivity() {
        let controller = GuidedMovementController(config: config)
        var t = passInitialCenter(controller)

        let working = feed(controller, from: t, duration: 0.2, pitch: 10)
        t += 0.3
        XCTAssertEqual(working.protocolPhase, .up)

        // Pausing mid-direction keeps the direction label.
        let paused = feed(controller, from: t, duration: 0.5, pitch: 10,
                          tracked: false)
        XCTAssertEqual(paused.protocolPhase, .up,
                       "a pause mid-direction must not relabel samples as center")
    }
}
