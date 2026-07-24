import XCTest
import simd
@testable import HeadPoseDistance

/// The head-position/distance boundary evaluator: distance band cues,
/// lateral tolerance, cue priority, and the stage-transition export additions.
final class FaceAlignmentTests: XCTestCase {

    private var config = MeasurementConfig.default

    private func evaluate(distance: Double? = 0.40,
                          deviation: Double? = nil,
                          translation: SIMD3<Float>? = SIMD3<Float>(0, 0, -0.4),
                          tracked: Bool = true) -> FaceAlignmentState {
        FaceAlignmentEvaluator.evaluate(primaryDistanceMeters: distance,
                                        deviationMeters: deviation,
                                        translation: translation,
                                        faceTracked: tracked,
                                        config: config)
    }

    // MARK: - Distance cues

    func testWithinPreferredRangeIsAligned() {
        let state = evaluate(distance: 0.40)
        XCTAssertEqual(state.distanceStatus, .ok)
        XCTAssertTrue(state.isAligned)
        XCTAssertNil(state.cue)
    }

    func testTooCloseAsksToMoveFarther() {
        let state = evaluate(distance: config.preferredMinDistanceMeters - 0.05)
        XCTAssertEqual(state.distanceStatus, .tooClose)
        XCTAssertEqual(state.cue, "Move farther")
        XCTAssertFalse(state.isAligned)
    }

    func testTooFarAsksToMoveCloser() {
        let state = evaluate(distance: config.preferredMaxDistanceMeters + 0.10)
        XCTAssertEqual(state.distanceStatus, .tooFar)
        XCTAssertEqual(state.cue, "Move closer")
    }

    func testBaselineDeviationTakesPriorityOverAbsoluteRange() {
        // Distance is inside the absolute preferred range, but the deviation
        // from the neutral baseline exceeds the guided band → too far.
        let state = evaluate(distance: 0.45,
                             deviation: config.guidedDistanceBandMeters + 0.02)
        XCTAssertEqual(state.distanceStatus, .tooFar)
        XCTAssertEqual(state.cue, "Move closer")
    }

    func testNegativeDeviationMeansTooClose() {
        let state = evaluate(deviation: -(config.guidedDistanceBandMeters + 0.02))
        XCTAssertEqual(state.distanceStatus, .tooClose)
        XCTAssertEqual(state.cue, "Move farther")
    }

    // MARK: - Lateral cues

    func testLateralOffsetBeyondToleranceProducesCue() {
        // Camera-space translation whose mapped user-right offset exceeds the
        // tolerance (convention: userRight = +t.y).
        let offset = Float(config.lateralOffsetToleranceMeters + 0.03)
        let state = evaluate(translation: SIMD3<Float>(0, offset, -0.4))
        XCTAssertFalse(state.withinLateralTolerance)
        XCTAssertEqual(state.cue, "Move left")
        XCTAssertFalse(state.isAligned)
    }

    func testVerticalOffsetProducesUpDownCue() {
        // Convention: userUp = −t.x, so a positive t.x is a downward offset.
        let offset = Float(config.lateralOffsetToleranceMeters + 0.03)
        let state = evaluate(translation: SIMD3<Float>(offset, 0, -0.4))
        XCTAssertEqual(state.cue, "Move up")
    }

    func testDistanceCueOutranksLateralCue() {
        let offset = Float(config.lateralOffsetToleranceMeters + 0.03)
        let state = evaluate(distance: config.preferredMaxDistanceMeters + 0.1,
                             translation: SIMD3<Float>(0, offset, -0.4))
        XCTAssertEqual(state.cue, "Move closer",
                       "distance correction must be requested first")
    }

    func testSmallOffsetsAreTolerated() {
        let offset = Float(config.lateralOffsetToleranceMeters * 0.5)
        let state = evaluate(translation: SIMD3<Float>(offset, -offset, -0.4))
        XCTAssertTrue(state.withinLateralTolerance)
        XCTAssertTrue(state.isAligned)
    }

    // MARK: - Tracking

    func testUntrackedFaceIsNeverAligned() {
        let state = evaluate(tracked: false)
        XCTAssertFalse(state.isAligned)
        XCTAssertEqual(state.cue, "Face not tracked")
        XCTAssertEqual(state.distanceStatus, .unknown)
    }

    // MARK: - Export integration

    func testStageTransitionsRoundTripThroughJSONExport() throws {
        let transitions = [
            GuidedMovementController.StageTransition(
                sessionElapsedSeconds: 1.5,
                fromState: "instructing_direction",
                toState: "moving_toward_target",
                stagePhase: "up",
                reason: "movement_started"),
            GuidedMovementController.StageTransition(
                sessionElapsedSeconds: 4.2,
                fromState: "holding_target_pose",
                toState: "returning_to_neutral",
                stagePhase: "up",
                reason: "hold_completed"),
        ]
        let recorder = SessionRecorder()
        let session = recorder.finish(metadata: SessionMetadata(),
                                      configuration: config,
                                      neutralPose: nil,
                                      durationSeconds: 10,
                                      stageTransitions: transitions)
        XCTAssertEqual(session.stageTransitions.count, 2)

        let document = JSONExporter.document(for: session, includeRejected: false)
        let data = try JSONExporter.data(for: document)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SessionExportDocument.self, from: data)
        XCTAssertEqual(decoded.stageTransitions, transitions)
    }

    func testEmptyTransitionsOmittedFromExport() throws {
        let recorder = SessionRecorder()
        let session = recorder.finish(metadata: SessionMetadata(),
                                      configuration: config,
                                      neutralPose: nil,
                                      durationSeconds: 10)
        let document = JSONExporter.document(for: session, includeRejected: false)
        XCTAssertNil(document.stageTransitions,
                     "no transitions → field omitted, preserving prior format")
    }
}
