import XCTest
@testable import HeadPoseDistance

/// Tests for the spiral sweep path.
///
/// The headline test is `testUniformArealSampleDensity`: the entire reason for
/// replacing the eight-spoke protocol is that it piles samples at neutral and
/// leaves the wedges empty, so "the spiral samples the field evenly" is a
/// claim that has to be measured, not asserted in a comment.
final class SpiralSweepPathTests: XCTestCase {

    private let config = MeasurementConfig.default
    private var path: SpiralSweepPath { SpiralSweepPath(config: config) }

    /// Normalized radius (0…1 of full amplitude) of a guide target.
    private func normalizedRadius(_ target: SpiralSweepPath.Target,
                                  _ path: SpiralSweepPath) -> Double {
        let x = target.yawDegrees / path.yawAmplitudeDegrees
        let y = target.pitchDegrees / path.pitchAmplitudeDegrees
        return (x * x + y * y).squareRoot()
    }

    // MARK: - The core claim

    /// Samples arrive at a fixed rate, so uniform progress steps stand in for
    /// uniform time steps. Binned into annuli of EQUAL AREA, a uniform-density
    /// path puts the same number of samples in every bin — a centre-heavy
    /// traversal (constant angular rate) would load the inner bins instead.
    func testUniformArealSampleDensity() {
        let path = self.path
        let sampleCount = 60_000
        let binCount = 12
        let r0 = path.innerRadiusFraction
        let inner = r0 * r0

        // Equal-area bin edges over the swept annulus [r0, 1].
        func binIndex(forRadius rho: Double) -> Int {
            let fraction = (rho * rho - inner) / (1 - inner)
            return min(binCount - 1, max(0, Int(fraction * Double(binCount))))
        }

        var counts = [Int](repeating: 0, count: binCount)
        for i in 0..<sampleCount {
            let u = Double(i) / Double(sampleCount - 1)
            counts[binIndex(forRadius: normalizedRadius(path.target(atProgress: u), path))] += 1
        }

        let expected = Double(sampleCount) / Double(binCount)
        for (index, count) in counts.enumerated() {
            let deviation = abs(Double(count) - expected) / expected
            XCTAssertLessThan(deviation, 0.02,
                              "equal-area bin \(index) holds \(count) samples, expected ~\(Int(expected)) (off by \(Int(deviation * 100))%)")
        }
    }

    /// The property that produces uniform areal density: constant tangential
    /// speed on the normalized path. Any significant peak-to-mean ratio would
    /// mean the guide dwells somewhere, re-creating the pile-up the spiral
    /// exists to avoid.
    func testTangentialSpeedIsEssentiallyConstant() {
        XCTAssertLessThan(path.normalizedSpeedUniformityRatio(), 1.05)
    }

    /// Degree-space speed is deliberately *not* constant: the elliptical
    /// amplitudes stretch yaw relative to pitch, so the guide covers degrees
    /// faster along yaw. The variation is bounded by the amplitude ratio and
    /// does not affect areal density (a linear map scales all areas equally).
    func testDegreeSpaceSpeedVariesOnlyByTheAmplitudeRatio() {
        let amplitudeRatio = config.sweepYawAmplitudeDegrees / config.sweepPitchAmplitudeDegrees
        XCTAssertLessThanOrEqual(path.speedUniformityRatio(), amplitudeRatio)
    }

    /// With equal amplitudes the ellipse degenerates to a circle and the
    /// degree-space speed becomes constant too — isolating the design
    /// property from the elliptical stretch.
    func testCircularPathHasConstantDegreeSpaceSpeed() {
        let circular = SpiralSweepPath(yawAmplitudeDegrees: 20,
                                       pitchAmplitudeDegrees: 20,
                                       turns: config.sweepTurns,
                                       innerRadiusFraction: config.sweepInnerRadiusFraction)
        XCTAssertLessThan(circular.speedUniformityRatio(), 1.05)
    }

    // MARK: - Bounds and endpoints

    func testStaysWithinConfiguredAmplitudes() {
        let path = self.path
        for i in 0...2000 {
            let target = path.target(atProgress: Double(i) / 2000)
            XCTAssertLessThanOrEqual(abs(target.yawDegrees),
                                     path.yawAmplitudeDegrees + 1e-9)
            XCTAssertLessThanOrEqual(abs(target.pitchDegrees),
                                     path.pitchAmplitudeDegrees + 1e-9)
        }
    }

    func testStartsAtInnerRadiusAndEndsAtFullAmplitude() {
        let path = self.path
        XCTAssertEqual(normalizedRadius(path.target(atProgress: 0), path),
                       path.innerRadiusFraction, accuracy: 1e-9)
        XCTAssertEqual(normalizedRadius(path.target(atProgress: 1), path),
                       1.0, accuracy: 1e-9)
    }

    func testProgressIsClampedAndNonFiniteIsSafe() {
        let path = self.path
        XCTAssertEqual(path.target(atProgress: -5), path.target(atProgress: 0))
        XCTAssertEqual(path.target(atProgress: 5), path.target(atProgress: 1))
        let nan = path.target(atProgress: .nan)
        XCTAssertEqual(nan.yawDegrees, 0)
        XCTAssertEqual(nan.pitchDegrees, 0)
    }

    /// No teleports: a guide that jumped would be unfollowable, and the head
    /// would stall rather than cover the path.
    func testPathIsContinuous() {
        let path = self.path
        let steps = 5000
        var previous = path.target(atProgress: 0)
        for i in 1...steps {
            let current = path.target(atProgress: Double(i) / Double(steps))
            let jump = SpiralSweepPath.trackingError(yawDegrees: previous.yawDegrees,
                                                     pitchDegrees: previous.pitchDegrees,
                                                     target: current)
            XCTAssertLessThan(jump, 0.5, "discontinuity at step \(i)")
            previous = current
        }
    }

    // MARK: - Coverage geometry

    /// Ring spacing has to stay at or below the heatmap's default
    /// `--sigma-min` (3°) plus a small margin, otherwise the adaptive kernel
    /// is again smoothing across unmeasured gaps — the exact failure the
    /// eight-spoke wedges caused.
    func testRingSpacingIsFineEnoughForTheHeatmapKernel() {
        XCTAssertEqual(path.ringSpacingFraction,
                       (1 - config.sweepInnerRadiusFraction) / config.sweepTurns,
                       accuracy: 1e-12)
        XCTAssertLessThanOrEqual(path.ringSpacingDegrees, 4.0)
    }

    // MARK: - Speed budget

    /// The guide must stay well under the too-fast threshold that would
    /// otherwise fire feedback continuously (and blur the Aria eye frames).
    func testDefaultDurationKeepsGuideBelowTooFastThreshold() {
        let peak = path.peakSpeedDegreesPerSecond(duration: config.sweepDurationSeconds)
        XCTAssertLessThan(peak, config.guidedMaxAngularVelocityDegPerSec)
        let mean = path.meanSpeedDegreesPerSecond(duration: config.sweepDurationSeconds)
        XCTAssertGreaterThan(mean, 1.0, "an implausibly slow guide would make sessions endless")
        XCTAssertLessThan(mean, 12.0)
    }

    /// A full sweep must yield enough Aria eye frames (20 Hz) to beat the
    /// ~1100-row reference dataset the previous gaze field was fit from.
    func testSweepYieldsEnoughEyeFrames() {
        let ariaFrames = config.sweepDurationSeconds * 20.0
        XCTAssertGreaterThan(ariaFrames, 1200)
    }

    // MARK: - Tracking error

    func testTrackingErrorIsPlanarDistance() {
        let target = SpiralSweepPath.Target(yawDegrees: 3, pitchDegrees: 4)
        XCTAssertEqual(SpiralSweepPath.trackingError(yawDegrees: 0, pitchDegrees: 0,
                                                     target: target),
                       5, accuracy: 1e-12)
        XCTAssertEqual(SpiralSweepPath.trackingError(yawDegrees: 3, pitchDegrees: 4,
                                                     target: target),
                       0, accuracy: 1e-12)
    }

    // MARK: - Degenerate configuration

    func testDegenerateParametersAreClamped() {
        let degenerate = SpiralSweepPath(yawAmplitudeDegrees: -10,
                                         pitchAmplitudeDegrees: -10,
                                         turns: 0,
                                         innerRadiusFraction: 5)
        XCTAssertEqual(degenerate.yawAmplitudeDegrees, 0)
        XCTAssertEqual(degenerate.turns, 0.5)
        XCTAssertEqual(degenerate.innerRadiusFraction, 0.9)
        // Must still produce finite output rather than NaN.
        let target = degenerate.target(atProgress: 0.5)
        XCTAssertTrue(target.yawDegrees.isFinite)
        XCTAssertTrue(target.pitchDegrees.isFinite)
    }
}
