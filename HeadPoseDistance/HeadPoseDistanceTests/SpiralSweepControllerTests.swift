import XCTest
@testable import HeadPoseDistance

/// Tests for the spiral sweep state machine.
///
/// Core invariant, shared with the eight-spoke protocol: coverage is earned by
/// the measured pose, never by elapsed time. Here that means the guide waits
/// whenever the head is not near it, so `sweepProgress` can always be read as
/// "this much of the path was actually traversed".
final class SpiralSweepControllerTests: XCTestCase {

    private var config: MeasurementConfig = {
        var c = MeasurementConfig.default
        // Short sweep keeps the tests fast; the path shape is unchanged.
        c.sweepDurationSeconds = 4.0
        return c
    }()

    private var path: SpiralSweepPath { SpiralSweepPath(config: config) }
    private let step = 1.0 / 30.0

    // MARK: - Helpers

    /// Feeds a fixed pose for `duration` seconds at ~30 Hz.
    @discardableResult
    private func feed(_ controller: SpiralSweepController,
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

    /// Feeds a head that tracks the guide exactly, with an optional constant
    /// lag applied to the guide position.
    @discardableResult
    private func follow(_ controller: SpiralSweepController,
                        from start: TimeInterval,
                        duration: TimeInterval,
                        offsetDegrees: Double = 0,
                        stability: PhoneStability = .stable) -> ProtocolGuidanceOutput {
        var output: ProtocolGuidanceOutput!
        var t = start
        while t <= start + duration {
            let target = path.target(atProgress: controller.progress)
            output = controller.update(.init(timestamp: t,
                                             faceTracked: true,
                                             yawDegrees: target.yawDegrees + offsetDegrees,
                                             pitchDegrees: target.pitchDegrees,
                                             angularVelocityDegPerSec: 5,
                                             distanceDeviationMeters: 0,
                                             lateralInBounds: true,
                                             phoneStability: stability))
            t += step
        }
        return output
    }

    /// Drives the controller through the initial centre hold so the sweep is
    /// running. Returns the time cursor.
    @discardableResult
    private func startSweep(_ controller: SpiralSweepController,
                            from start: TimeInterval = 0) -> TimeInterval {
        let duration = config.neutralHoldSeconds + 0.5
        feed(controller, from: start, duration: duration, yaw: 0, pitch: 0)
        XCTAssertEqual(controller.state, .sweeping)
        return start + duration + step
    }

    // MARK: - Entry

    func testSweepDoesNotStartUntilNeutralIsHeld() {
        let controller = SpiralSweepController(config: config)

        // Head far off neutral: never leaves the centring state.
        let output = feed(controller, from: 0, duration: 3.0, yaw: 18, pitch: 12)
        XCTAssertEqual(controller.state, .returningToNeutral)
        XCTAssertEqual(controller.progress, 0)
        XCTAssertNil(output.sweep, "no guide outline before the sweep begins")
        XCTAssertEqual(output.protocolPhase, .center)
    }

    func testSweepStartsAfterNeutralHold() {
        let controller = SpiralSweepController(config: config)
        startSweep(controller)
        XCTAssertTrue(controller.transitions.contains { $0.reason == "sweep_started" })
    }

    // MARK: - The central invariant

    /// Progress must reflect traversal, not the clock. A head parked at
    /// neutral follows the guide only while it is still near the centre; once
    /// the spiral moves away the guide stalls and progress stops.
    func testStationaryHeadStallsTheGuideInsteadOfAdvancing() {
        let controller = SpiralSweepController(config: config)
        let t = startSweep(controller)

        // Far longer than the whole sweep duration.
        let output = feed(controller, from: t, duration: config.sweepDurationSeconds * 3,
                          yaw: 0, pitch: 0)

        XCTAssertEqual(controller.state, .sweepStalled)
        XCTAssertLessThan(controller.progress, 0.25,
                          "a motionless head must not accumulate coverage")
        XCTAssertGreaterThan(controller.progress, 0,
                             "the guide starts near neutral, so a little progress is expected")
        XCTAssertTrue(output.sweep?.isStalled ?? false)
        XCTAssertEqual(output.feedback, .behindGuide)
    }

    func testFollowingTheGuideAdvancesProgress() {
        let controller = SpiralSweepController(config: config)
        let t = startSweep(controller)
        follow(controller, from: t, duration: config.sweepDurationSeconds * 0.5)
        XCTAssertEqual(controller.state, .sweeping)
        XCTAssertGreaterThan(controller.progress, 0.4)
        XCTAssertLessThan(controller.progress, 0.7)
    }

    func testSweepProgressAndTargetAreReported() {
        let controller = SpiralSweepController(config: config)
        let t = startSweep(controller)
        let output = follow(controller, from: t, duration: 1.0)

        let sweep = try? XCTUnwrap(output.sweep)
        XCTAssertNotNil(sweep)
        XCTAssertEqual(output.protocolPhase, .sweep)
        XCTAssertEqual(sweep?.progress ?? -1, controller.progress, accuracy: 1e-9)

        let expected = path.target(atProgress: controller.progress)
        XCTAssertEqual(sweep?.targetYawDegrees ?? .nan, expected.yawDegrees, accuracy: 1e-9)
        XCTAssertEqual(sweep?.targetPitchDegrees ?? .nan, expected.pitchDegrees, accuracy: 1e-9)

        // A perfect follower still shows one frame of lag, by construction:
        // the pose fed for frame N is the guide position at the *start* of
        // that frame, and update() advances the guide before reporting the
        // error. This test's sweep is compressed to 4 s (vs 75 s shipped), so
        // one frame of guide travel is ~3° here and ~0.2° in a real session.
        let oneFrameOfGuideTravel =
            path.pathLengthDegrees() / config.sweepDurationSeconds * step
        XCTAssertLessThan(sweep?.trackingErrorDegrees ?? .infinity,
                          oneFrameOfGuideTravel * 1.5)
    }

    // MARK: - Stall hysteresis

    func testStallResumesOnlyInsideTheTighterResumeBand() {
        let controller = SpiralSweepController(config: config)
        let t = startSweep(controller)

        // Lag beyond the stall tolerance.
        let lag = config.sweepFollowToleranceDegrees + 2
        var cursor = t
        follow(controller, from: cursor, duration: 0.5, offsetDegrees: lag)
        cursor += 0.5 + step
        XCTAssertEqual(controller.state, .sweepStalled)
        let stalledProgress = controller.progress

        // Between the resume and stall thresholds: still stalled (hysteresis).
        let between = (config.sweepFollowResumeDegrees
                       + config.sweepFollowToleranceDegrees) / 2
        follow(controller, from: cursor, duration: 0.5, offsetDegrees: between)
        cursor += 0.5 + step
        XCTAssertEqual(controller.state, .sweepStalled)
        XCTAssertEqual(controller.progress, stalledProgress, accuracy: 1e-9,
                       "a stalled guide must not accumulate progress")

        // Inside the resume band: sweeping again.
        follow(controller, from: cursor, duration: 0.3,
               offsetDegrees: config.sweepFollowResumeDegrees - 1)
        XCTAssertEqual(controller.state, .sweeping)
        XCTAssertGreaterThan(controller.progress, stalledProgress)
    }

    // MARK: - Pauses

    func testTrackingLossPausesAndDoesNotAdvanceProgress() {
        let controller = SpiralSweepController(config: config)
        let t = startSweep(controller)
        follow(controller, from: t, duration: 0.5)
        let progressBeforePause = controller.progress

        let cursor = t + 0.5 + step
        feed(controller, from: cursor, duration: 1.0, tracked: false)
        XCTAssertEqual(controller.state, .pausedForTracking)
        XCTAssertEqual(controller.progress, progressBeforePause, accuracy: 1e-9)

        // Recovering resumes into the sweep.
        follow(controller, from: cursor + 1.0 + step, duration: 0.3)
        XCTAssertEqual(controller.state, .sweeping)
        XCTAssertGreaterThan(controller.progress, progressBeforePause)
    }

    func testExcessivePhoneMotionPauses() {
        let controller = SpiralSweepController(config: config)
        let t = startSweep(controller)
        follow(controller, from: t, duration: 0.3, stability: .excessive)
        XCTAssertEqual(controller.state, .pausedForPhoneMotion)
        XCTAssertTrue(controller.transitions.contains { $0.reason == "phone_motion_excessive" })
    }

    func testDistanceDriftPausesAfterHysteresisWindow() {
        let controller = SpiralSweepController(config: config)
        let t = startSweep(controller)
        let progressBefore = controller.progress

        let drift = config.guidedDistanceBandMeters + 0.02
        feed(controller, from: t, duration: config.distancePauseEnterSeconds + 0.4,
             yaw: 0, pitch: 0, deviation: drift)
        XCTAssertEqual(controller.state, .pausedForDistance)
        XCTAssertLessThan(controller.progress - progressBefore, 0.2)
    }

    func testLateralDriftPauses() {
        let controller = SpiralSweepController(config: config)
        let t = startSweep(controller)
        feed(controller, from: t, duration: config.distancePauseEnterSeconds + 0.4,
             yaw: 0, pitch: 0, lateralInBounds: false)
        XCTAssertEqual(controller.state, .pausedForDistance)
    }

    /// A pause mid-sweep must keep labelling samples `sweep`, not `center` —
    /// otherwise paused frames would be misfiled into the neutral cluster.
    func testPausedMidSweepStillLabelsSamplesAsSweep() {
        let controller = SpiralSweepController(config: config)
        let t = startSweep(controller)
        follow(controller, from: t, duration: 0.5)
        let output = feed(controller, from: t + 0.5 + step, duration: 0.5, tracked: false)
        XCTAssertEqual(output.protocolPhase, .sweep)
    }

    // MARK: - Completion

    func testFullSweepThenReturnToNeutralCompletes() {
        let controller = SpiralSweepController(config: config)
        var cursor = startSweep(controller)

        // Traverse the whole path.
        follow(controller, from: cursor, duration: config.sweepDurationSeconds + 1.0)
        cursor += config.sweepDurationSeconds + 1.0 + step
        XCTAssertTrue(controller.sweepFinished)
        XCTAssertEqual(controller.progress, 1.0, accuracy: 1e-9)
        XCTAssertTrue(controller.transitions.contains { $0.reason == "sweep_completed" })

        // Return to neutral and hold to finish.
        let output = feed(controller, from: cursor,
                          duration: config.neutralHoldSeconds + 0.5, yaw: 0, pitch: 0)
        XCTAssertEqual(controller.state, .complete)
        XCTAssertTrue(output.isComplete)
        XCTAssertEqual(output.protocolPhase, .complete)
        XCTAssertTrue(controller.transitions.contains { $0.reason == "all_stages_complete" })
    }

    /// The sweep never auto-completes on elapsed time — that is the whole
    /// point of gating progress on the pose.
    func testNeverCompletesWithoutTraversingThePath() {
        let controller = SpiralSweepController(config: config)
        let t = startSweep(controller)
        feed(controller, from: t, duration: config.sweepDurationSeconds * 5,
             yaw: 0, pitch: 0)
        XCTAssertNotEqual(controller.state, .complete)
        XCTAssertFalse(controller.sweepFinished)
    }

    // MARK: - Timestamp gaps

    /// Backgrounding produces a large timestamp jump; it must not be credited
    /// as sweep coverage.
    func testLargeUpdateGapIsNotCreditedAsProgress() {
        let controller = SpiralSweepController(config: config)
        let t = startSweep(controller)
        follow(controller, from: t, duration: 0.3)
        let before = controller.progress

        // One update 30 s later — far beyond updateGapResetSeconds.
        let target = path.target(atProgress: controller.progress)
        _ = controller.update(.init(timestamp: t + 0.3 + 30,
                                    faceTracked: true,
                                    yawDegrees: target.yawDegrees,
                                    pitchDegrees: target.pitchDegrees,
                                    angularVelocityDegPerSec: 5,
                                    distanceDeviationMeters: 0,
                                    lateralInBounds: true,
                                    phoneStability: .stable))
        XCTAssertEqual(controller.progress, before, accuracy: 1e-9)
    }

    // MARK: - Transition log

    func testTransitionsAreRecordedWithReasons() {
        let controller = SpiralSweepController(config: config)
        let t = startSweep(controller)
        follow(controller, from: t, duration: 0.5)

        XCTAssertFalse(controller.transitions.isEmpty)
        XCTAssertEqual(controller.transitions.first?.reason, "recording_started")
        for transition in controller.transitions {
            XCTAssertFalse(transition.reason.isEmpty)
            XCTAssertFalse(transition.toState.isEmpty)
            XCTAssertTrue(transition.sessionElapsedSeconds >= 0)
        }
    }
}
