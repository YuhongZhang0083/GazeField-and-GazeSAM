import XCTest
@testable import HeadPoseDistance

/// Tests for the coverage grid — the thing that now *defines* whether a
/// free-exploration session produced usable gaze-field data.
final class CoverageGridTests: XCTestCase {

    private let config = MeasurementConfig.default
    private func makeGrid() -> CoverageGrid { CoverageGrid(config: config) }

    // MARK: - Geometry

    /// 7 × 5 over an elliptical field: the four corners fall outside and are
    /// not required, leaving 31 cells. If this number moves, the completion
    /// threshold and the session length move with it.
    func testEllipticalFieldHasExpectedRequiredCellCount() {
        let grid = makeGrid()
        XCTAssertEqual(grid.requiredCellCount, 31)
        // Corners are outside the ellipse.
        XCTAssertFalse(grid.isRequired(column: 0, row: 0))
        XCTAssertFalse(grid.isRequired(column: 6, row: 0))
        XCTAssertFalse(grid.isRequired(column: 0, row: 4))
        XCTAssertFalse(grid.isRequired(column: 6, row: 4))
        // Centre and the axis extremes are inside.
        XCTAssertTrue(grid.isRequired(column: 3, row: 2))
        XCTAssertTrue(grid.isRequired(column: 0, row: 2))
        XCTAssertTrue(grid.isRequired(column: 6, row: 2))
        XCTAssertTrue(grid.isRequired(column: 3, row: 0))
        XCTAssertTrue(grid.isRequired(column: 3, row: 4))
    }

    /// Yaw increases to the right, pitch increases upward (row 0 is the top) —
    /// matching the mirrored virtual head, so the grid reads as a map of where
    /// the head is rather than an abstract meter.
    func testCellMappingOrientation() {
        let grid = makeGrid()
        let centre = grid.cell(yawDegrees: 0, pitchDegrees: 0)
        XCTAssertEqual(centre?.column, 3)
        XCTAssertEqual(centre?.row, 2)

        let right = grid.cell(yawDegrees: 20, pitchDegrees: 0)
        XCTAssertEqual(right?.column, 6)
        XCTAssertEqual(right?.row, 2)

        let left = grid.cell(yawDegrees: -20, pitchDegrees: 0)
        XCTAssertEqual(left?.column, 0)

        let up = grid.cell(yawDegrees: 0, pitchDegrees: 15)
        XCTAssertEqual(up?.row, 0, "positive pitch must map to the TOP row")

        let down = grid.cell(yawDegrees: 0, pitchDegrees: -15)
        XCTAssertEqual(down?.row, 4)
    }

    func testPosesFarOutsideTheFieldAreRejected() {
        let grid = makeGrid()
        XCTAssertNil(grid.cell(yawDegrees: 60, pitchDegrees: 0))
        XCTAssertNil(grid.cell(yawDegrees: 0, pitchDegrees: 40))
        XCTAssertNil(grid.cell(yawDegrees: .nan, pitchDegrees: 0))
    }

    /// A slight overshoot still earns credit for the edge cell — without slack
    /// a participant who went 1° too far would get nothing for the effort.
    func testSlightOvershootIsClampedIntoTheEdgeCell() {
        let grid = makeGrid()
        let overshoot = grid.cell(yawDegrees: config.coverageYawAmplitudeDegrees * 1.1,
                                  pitchDegrees: 0)
        XCTAssertEqual(overshoot?.column, grid.columns - 1)
        XCTAssertEqual(overshoot?.row, 2)
    }

    // MARK: - Accumulation

    /// A cell needs a dwell, not a drive-by: one frame must not claim it.
    func testCellNeedsFullSampleCountBeforeItCounts() {
        var grid = makeGrid()
        for i in 1..<config.coverageSamplesPerCell {
            let completed = grid.add(yawDegrees: 0, pitchDegrees: 0)
            XCTAssertFalse(completed, "cell completed early at sample \(i)")
            XCTAssertFalse(grid.isCovered(column: 3, row: 2))
        }
        let completed = grid.add(yawDegrees: 0, pitchDegrees: 0)
        XCTAssertTrue(completed, "the final sample must report completion")
        XCTAssertTrue(grid.isCovered(column: 3, row: 2))
    }

    /// Completion is reported exactly once, so the haptic ticks once per cell.
    func testCompletionIsReportedOnlyOnce() {
        var grid = makeGrid()
        for _ in 0..<config.coverageSamplesPerCell {
            _ = grid.add(yawDegrees: 0, pitchDegrees: 0)
        }
        for _ in 0..<20 {
            XCTAssertFalse(grid.add(yawDegrees: 0, pitchDegrees: 0),
                           "an already-covered cell must not re-report")
        }
    }

    /// Filling a cell outside the elliptical field must not report completion —
    /// it is bonus data, and a haptic tick there would be misleading.
    func testNonRequiredCellDoesNotReportCompletion() {
        var grid = makeGrid()
        // Upper-left corner cell: its CENTRE is outside the ellipse (so the
        // cell is not required) but its inner corner is still within the
        // acceptance radius, so the cell is reachable.
        let yaw = -config.coverageYawAmplitudeDegrees * 0.72
        let pitch = config.coveragePitchAmplitudeDegrees * 0.62
        guard let cell = grid.cell(yawDegrees: yaw, pitchDegrees: pitch) else {
            return XCTFail("pose should still be inside the accepted field")
        }
        XCTAssertFalse(grid.isRequired(column: cell.column, row: cell.row))

        var reported = false
        for _ in 0..<(config.coverageSamplesPerCell * 2) {
            reported = grid.add(yawDegrees: yaw, pitchDegrees: pitch) || reported
        }
        XCTAssertFalse(reported)
        XCTAssertEqual(grid.coveredRequiredCellCount, 0)
        // …but the data is still counted, never discarded.
        XCTAssertGreaterThan(grid.sampleCount(column: cell.column, row: cell.row), 0)
    }

    func testFillFractionRampsFromZeroToOne() {
        var grid = makeGrid()
        XCTAssertEqual(grid.fillFraction(column: 3, row: 2), 0)
        for _ in 0..<(config.coverageSamplesPerCell / 2) {
            _ = grid.add(yawDegrees: 0, pitchDegrees: 0)
        }
        let mid = grid.fillFraction(column: 3, row: 2)
        XCTAssertGreaterThan(mid, 0)
        XCTAssertLessThan(mid, 1)
        for _ in 0..<config.coverageSamplesPerCell {
            _ = grid.add(yawDegrees: 0, pitchDegrees: 0)
        }
        XCTAssertEqual(grid.fillFraction(column: 3, row: 2), 1, "must clamp at 1")
    }

    // MARK: - Progress

    func testCoveredFractionReachesOneOnlyWhenEveryRequiredCellIsFilled() {
        var grid = makeGrid()
        for row in 0..<grid.rows {
            for column in 0..<grid.columns where grid.isRequired(column: column, row: row) {
                let centre = grid.cellCenter(column: column, row: row)
                for _ in 0..<config.coverageSamplesPerCell {
                    _ = grid.add(yawDegrees: centre.u * config.coverageYawAmplitudeDegrees,
                                 pitchDegrees: centre.v * config.coveragePitchAmplitudeDegrees)
                }
            }
        }
        XCTAssertEqual(grid.coveredRequiredCellCount, grid.requiredCellCount)
        XCTAssertEqual(grid.coveredFraction, 1.0, accuracy: 1e-12)
    }

    /// Covering only the centre — what the eight-spoke protocol over-samples —
    /// must leave the fraction near zero. This is the failure the grid exists
    /// to make visible.
    func testCentreOnlyCoverageStaysNearZero() {
        var grid = makeGrid()
        for _ in 0..<5000 {
            _ = grid.add(yawDegrees: 0, pitchDegrees: 0)
        }
        XCTAssertEqual(grid.coveredRequiredCellCount, 1)
        XCTAssertLessThan(grid.coveredFraction, 0.05)
    }

    /// Eight spokes at full amplitude plus the centre: the protocol kept for
    /// validation cannot reach the completion threshold, which is exactly why
    /// it is not the training protocol.
    func testEightSpokePatternCannotReachCompletionThreshold() {
        var grid = makeGrid()
        let a = config.coverageYawAmplitudeDegrees
        let b = config.coveragePitchAmplitudeDegrees
        let d = 1.0 / 2.0.squareRoot()
        let spokes: [(Double, Double)] = [
            (0, 0), (0, b), (0, -b), (-a, 0), (a, 0),
            (-a * d, b * d), (a * d, b * d), (-a * d, -b * d), (a * d, -b * d),
        ]
        // Dense sampling along each spoke, as 60 Hz recording would produce.
        for (yaw, pitch) in spokes {
            for step in 0...40 {
                let f = Double(step) / 40
                for _ in 0..<config.coverageSamplesPerCell {
                    _ = grid.add(yawDegrees: yaw * f, pitchDegrees: pitch * f)
                }
            }
        }
        XCTAssertLessThan(grid.coveredFraction, config.coverageCompletionFraction,
                          "spokes leave the wedges empty, so they must not read as complete")
    }

    func testResetClearsCounts() {
        var grid = makeGrid()
        for _ in 0..<config.coverageSamplesPerCell {
            _ = grid.add(yawDegrees: 0, pitchDegrees: 0)
        }
        grid.reset()
        XCTAssertEqual(grid.coveredRequiredCellCount, 0)
        XCTAssertEqual(grid.fillFraction(column: 3, row: 2), 0)
    }

    // MARK: - View payload

    func testFillAndRequiredArraysMatchGridShape() {
        let grid = makeGrid()
        XCTAssertEqual(grid.fillFractions.count, grid.columns * grid.rows)
        XCTAssertEqual(grid.requiredFlags.count, grid.columns * grid.rows)
        // Row-major, top row first: index 0 is the top-left corner cell, which
        // is outside the ellipse.
        XCTAssertFalse(grid.requiredFlags[0])
    }

    // MARK: - Degenerate configuration

    func testDegenerateParametersAreClamped() {
        let grid = CoverageGrid(columns: 0, rows: 0,
                               yawAmplitudeDegrees: 0, pitchAmplitudeDegrees: -5,
                               samplesPerCell: 0)
        XCTAssertEqual(grid.columns, 1)
        XCTAssertEqual(grid.rows, 1)
        XCTAssertEqual(grid.samplesPerCell, 1)
        XCTAssertGreaterThan(grid.yawAmplitudeDegrees, 0)
        XCTAssertGreaterThan(grid.pitchAmplitudeDegrees, 0)
    }
}
