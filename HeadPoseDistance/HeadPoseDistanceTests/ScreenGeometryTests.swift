import XCTest
import simd
@testable import HeadPoseDistance

/// Validation for the dot-vs-camera offset fix.
///
/// Reported symptom: sitting at the true neutral position — eye on the fixation
/// dot — the app showed "Move up" and drew the virtual head low in the oval.
/// Cause: setup alignment was measured from the TrueDepth camera axis, but the
/// dot sits ~26% down the screen, several centimetres below the camera, so a
/// correctly positioned face reads as too low.
final class ScreenGeometryTests: XCTestCase {

    private var config = MeasurementConfig.default

    /// Geometry matching the reported device: a 6.1" Face ID iPhone in portrait,
    /// with the dot placed by `dotAnchorYFraction` inside the safe area.
    private func reportedGeometry() -> ScreenGeometry {
        let safeTop: Double = 59
        let safeHeight: Double = 780
        let width: Double = 393
        let dotY = safeTop + safeHeight * config.dotAnchorYFraction
        return ScreenGeometry(widthPoints: width,
                              scale: 3,
                              dotCenterGlobal: CGPoint(x: width / 2, y: dotY),
                              cameraCenterYPoints: config.cameraCenterYPoints)
    }

    // MARK: - Conversion

    func testPointsPerInchMatchesDisplayScale() {
        XCTAssertEqual(ScreenGeometry.pointsPerInch(scale: 3), 153.3, accuracy: 0.01)
        XCTAssertEqual(ScreenGeometry.pointsPerInch(scale: 2), 163.0, accuracy: 0.01)
    }

    /// A sanity anchor on the whole conversion chain: a 393 pt wide @3x display
    /// is ~6.5 cm of glass, which is the physical width of a 6.1" iPhone.
    func testPointsToMetersIsPhysicallyPlausible() {
        let geometry = reportedGeometry()
        let widthMeters = geometry.widthPoints / geometry.pointsPerMeter
        XCTAssertEqual(widthMeters, 0.065, accuracy: 0.004)
    }

    // MARK: - The expected offset

    /// The dot is below the camera, so the expected face position is BELOW the
    /// camera axis — a negative "up" offset. A positive value here would push
    /// the participant the wrong way and make the bug worse.
    func testExpectedOffsetPutsTheFaceBelowTheCameraAxis() {
        let offset = reportedGeometry().expectedFaceOffset
        XCTAssertLessThan(offset.userUpMeters, 0)
        // ~230 pt at ~6035 pt/m ≈ 3.8 cm. Bracketed generously because the
        // camera position is approximate.
        XCTAssertEqual(offset.userUpMeters, -0.038, accuracy: 0.008)
    }

    /// Camera and dot are both horizontally centred, so there is nothing to
    /// correct sideways — a non-zero value would introduce a lateral bias.
    func testExpectedOffsetHasNoHorizontalComponentForACentredDot() {
        XCTAssertEqual(reportedGeometry().expectedFaceOffset.userRightMeters,
                       0, accuracy: 1e-9)
    }

    /// The correction must be a meaningful fraction of the tolerance it is
    /// judged against — if it were negligible it could not have caused the
    /// reported cue, and this fix would be treating the wrong thing.
    func testCorrectionIsLargeEnoughToExplainTheReportedCue() {
        let offset = reportedGeometry().expectedFaceOffset
        let ratio = abs(offset.userUpMeters) / config.lateralOffsetToleranceMeters
        XCTAssertGreaterThan(ratio, 0.5,
                             "correction should be a large fraction of the 5 cm tolerance")
        XCTAssertLessThan(ratio, 1.5, "…but not so large it implies a different bug")
    }

    /// Moving the dot toward the camera must shrink the correction, and to the
    /// camera itself must eliminate it. This pins the direction of the whole
    /// relationship rather than one magic number.
    func testCorrectionScalesWithDotDistanceFromTheCamera() {
        var geometry = reportedGeometry()
        let far = geometry.expectedFaceOffset.userUpMeters

        geometry.dotCenterGlobal.y = geometry.cameraCenterYPoints + 100
        let near = geometry.expectedFaceOffset.userUpMeters
        XCTAssertGreaterThan(near, far, "a closer dot means a smaller downward offset")

        geometry.dotCenterGlobal.y = geometry.cameraCenterYPoints
        XCTAssertEqual(geometry.expectedFaceOffset.userUpMeters, 0, accuracy: 1e-9,
                       "a dot at the camera needs no correction at all")
    }

    func testDegenerateGeometryYieldsNoCorrection() {
        let bad = ScreenGeometry(widthPoints: 0, scale: 0,
                                 dotCenterGlobal: .zero, cameraCenterYPoints: 28)
        XCTAssertEqual(bad.expectedFaceOffset, .zero)
    }

    // MARK: - End-to-end through the evaluator

    /// Camera-space translation for a face sitting `upMeters` above the camera
    /// axis, using the documented convention (`up = −translation.x`).
    private func translation(upMeters: Double, rightMeters: Double = 0) -> SIMD3<Float> {
        let convention = AlignmentConvention.default
        let x = Float(upMeters / convention.userUpFromCameraX)
        let y = Float(rightMeters / convention.userRightFromCameraY)
        return SIMD3<Float>(x, y, -0.4)
    }

    /// THE REGRESSION TEST. A face at the true neutral position — on the dot's
    /// normal axis — must report aligned, with no cue and a centred head.
    func testFaceOnTheDotAxisReportsAlignedInsteadOfMoveUp() {
        let expected = reportedGeometry().expectedFaceOffset
        let state = FaceAlignmentEvaluator.evaluate(
            primaryDistanceMeters: 0.41,
            deviationMeters: nil,
            translation: translation(upMeters: expected.userUpMeters),
            neutralTranslation: nil,
            faceTracked: true,
            config: config,
            expectedOffset: expected)

        XCTAssertNil(state.cue, "correctly positioned face must not be nagged")
        XCTAssertTrue(state.isAligned)
        XCTAssertEqual(state.userUpOffsetMeters ?? .nan, 0, accuracy: 1e-6,
                       "the head must be drawn centred, not low")
    }

    /// The old behaviour, pinned so the fix cannot silently regress: without the
    /// correction the very same correctly-positioned face is told to move up.
    func testWithoutTheCorrectionTheSameFaceIsWronglyToldToMoveUp() {
        let expected = reportedGeometry().expectedFaceOffset
        // A face 2 cm below the dot axis — a perfectly ordinary neutral posture,
        // but 5.8 cm below the CAMERA axis, which is what the old code measured
        // against and what pushed it past the 5 cm tolerance.
        let actualUp = expected.userUpMeters - 0.02
        let uncorrected = FaceAlignmentEvaluator.evaluate(
            primaryDistanceMeters: 0.41,
            deviationMeters: nil,
            translation: translation(upMeters: actualUp),
            neutralTranslation: nil,
            faceTracked: true,
            config: config,
            expectedOffset: .zero)
        XCTAssertEqual(uncorrected.cue, "Move up", "reproduces the reported symptom")

        let corrected = FaceAlignmentEvaluator.evaluate(
            primaryDistanceMeters: 0.41,
            deviationMeters: nil,
            translation: translation(upMeters: actualUp),
            neutralTranslation: nil,
            faceTracked: true,
            config: config,
            expectedOffset: expected)
        XCTAssertNil(corrected.cue, "…and the correction removes it")
    }

    /// A face genuinely too low must still be told to move up — the fix must not
    /// simply disable the cue.
    func testAFaceGenuinelyTooLowIsStillToldToMoveUp() {
        let expected = reportedGeometry().expectedFaceOffset
        let tooLow = expected.userUpMeters - config.lateralOffsetToleranceMeters - 0.02
        let state = FaceAlignmentEvaluator.evaluate(
            primaryDistanceMeters: 0.41,
            deviationMeters: nil,
            translation: translation(upMeters: tooLow),
            neutralTranslation: nil,
            faceTracked: true,
            config: config,
            expectedOffset: expected)
        XCTAssertEqual(state.cue, "Move up")
        XCTAssertFalse(state.isAligned)
    }

    /// And a face on the CAMERA axis is now correctly told to move down, since
    /// that position looks at the dot from above.
    func testFaceOnTheCameraAxisIsToldToMoveDown() {
        let expected = reportedGeometry().expectedFaceOffset
        var loose = config
        // Tolerance below the correction, so the camera-axis position is out of
        // bounds and produces a directional cue.
        loose.lateralOffsetToleranceMeters = 0.02
        let state = FaceAlignmentEvaluator.evaluate(
            primaryDistanceMeters: 0.41,
            deviationMeters: nil,
            translation: translation(upMeters: 0),
            neutralTranslation: nil,
            faceTracked: true,
            config: loose,
            expectedOffset: expected)
        XCTAssertEqual(state.cue, "Move down",
                       "the camera axis is above the dot axis, so the face must come down")
    }

    /// Once a neutral pose exists, the reference is that pose and the setup
    /// correction must NOT be applied again — otherwise the fixed bounds used
    /// during recording would be biased by the dot offset.
    func testCorrectionIsNotAppliedOnceNeutralExists() {
        let expected = reportedGeometry().expectedFaceOffset
        let neutral = translation(upMeters: expected.userUpMeters)
        let state = FaceAlignmentEvaluator.evaluate(
            primaryDistanceMeters: 0.41,
            deviationMeters: 0,
            translation: neutral,
            neutralTranslation: neutral,
            faceTracked: true,
            config: config,
            expectedOffset: expected)

        XCTAssertEqual(state.userUpOffsetMeters ?? .nan, 0, accuracy: 1e-6)
        XCTAssertNil(state.cue)
        XCTAssertTrue(state.isAligned)
    }

    /// Horizontal cues must be untouched by a purely vertical correction.
    func testHorizontalCuesAreUnaffected() {
        let expected = reportedGeometry().expectedFaceOffset
        let offRight = config.lateralOffsetToleranceMeters + 0.02
        let state = FaceAlignmentEvaluator.evaluate(
            primaryDistanceMeters: 0.41,
            deviationMeters: nil,
            translation: translation(upMeters: expected.userUpMeters, rightMeters: offRight),
            neutralTranslation: nil,
            faceTracked: true,
            config: config,
            expectedOffset: expected)
        XCTAssertEqual(state.cue, "Move left")
    }
}
