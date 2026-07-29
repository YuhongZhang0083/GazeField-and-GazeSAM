import XCTest
@testable import HeadPoseDistance

/// Tests for the coverage grid — the thing that now *defines* whether a
/// free-exploration session produced usable gaze-field data.
final class CoverageGridTests: XCTestCase {

    private let config = MeasurementConfig.default
    private func makeGrid() -> CoverageGrid { CoverageGrid(config: config) }

    // MARK: - Geometry

    /// The default field is the FULL rectangle — every cell required, corners
    /// included — so the grid spans the whole configured field of view with no
    /// region left for the heatmap to extrapolate across.
    func testDefaultFieldCoversTheFullRectangle() {
        let grid = makeGrid()
        XCTAssertEqual(grid.requiredCellCount, grid.columns * grid.rows)
        XCTAssertEqual(grid.requiredCellCount, 99)
        for row in 0..<grid.rows {
            for column in 0..<grid.columns {
                XCTAssertTrue(grid.isRequired(column: column, row: row),
                              "cell (\(column), \(row)) must be required")
            }
        }
    }

    /// THE INVARIANT THAT MATTERS: every required cell must be reachable. Each
    /// cell's own centre pose has to map back to that same cell.
    ///
    /// An earlier version failed this. Requirement was rectangular but pose
    /// *acceptance* was radial, so the corner cells — normalized radius ~1.6 —
    /// had their own centres rejected: required but impossible to fill, which
    /// would have stalled every session short of completion.
    func testEveryRequiredCellIsReachableFromItsOwnCentre() {
        let grid = makeGrid()
        for row in 0..<grid.rows {
            for column in 0..<grid.columns where grid.isRequired(column: column, row: row) {
                let centre = grid.cellCenter(column: column, row: row)
                let yaw = centre.u * grid.yawAmplitudeDegrees
                let pitch = centre.v * grid.pitchAmplitudeDegrees
                guard let hit = grid.cell(yawDegrees: yaw, pitchDegrees: pitch) else {
                    XCTFail("required cell (\(column), \(row)) rejects its own centre")
                    continue
                }
                XCTAssertEqual(hit.column, column, "row \(row) column mismatch")
                XCTAssertEqual(hit.row, row, "column \(column) row mismatch")
            }
        }
    }

    /// The whole required field must be fillable end to end, not just cell by
    /// cell — a completion threshold no one can reach is worse than none.
    func testTheFullFieldCanActuallyReachCompletion() {
        var grid = makeGrid()
        for row in 0..<grid.rows {
            for column in 0..<grid.columns where grid.isRequired(column: column, row: row) {
                let centre = grid.cellCenter(column: column, row: row)
                for _ in 0..<grid.samplesPerCell {
                    _ = grid.add(yawDegrees: centre.u * grid.yawAmplitudeDegrees,
                                 pitchDegrees: centre.v * grid.pitchAmplitudeDegrees)
                }
            }
        }
        XCTAssertEqual(grid.coveredFraction, 1.0, accuracy: 1e-12)
        XCTAssertGreaterThanOrEqual(grid.coveredFraction, config.coverageCompletionFraction)
    }

    /// Missing only the four corners must still allow completion: they demand
    /// the largest combined rotation and are the plausible casualty.
    func testMissingOnlyTheCornersStillCompletes() {
        var grid = makeGrid()
        let corners: Set<[Int]> = [[0, 0], [grid.columns - 1, 0],
                                   [0, grid.rows - 1], [grid.columns - 1, grid.rows - 1]]
        for row in 0..<grid.rows {
            for column in 0..<grid.columns where !corners.contains([column, row]) {
                let centre = grid.cellCenter(column: column, row: row)
                for _ in 0..<grid.samplesPerCell {
                    _ = grid.add(yawDegrees: centre.u * grid.yawAmplitudeDegrees,
                                 pitchDegrees: centre.v * grid.pitchAmplitudeDegrees)
                }
            }
        }
        XCTAssertGreaterThanOrEqual(grid.coveredFraction, config.coverageCompletionFraction,
                                    "the threshold must tolerate losing the four corners")
    }

    /// The ellipse mode is still available and still excludes the corners.
    func testEllipseModeExcludesCornersButKeepsAxisExtremes() {
        let grid = CoverageGrid(columns: 11, rows: 9,
                                yawAmplitudeDegrees: 25, pitchAmplitudeDegrees: 18,
                                samplesPerCell: 8, requiresCorners: false)
        XCTAssertLessThan(grid.requiredCellCount, grid.columns * grid.rows)
        XCTAssertFalse(grid.isRequired(column: 0, row: 0))
        XCTAssertFalse(grid.isRequired(column: 10, row: 8))
        XCTAssertTrue(grid.isRequired(column: 5, row: 4))
        XCTAssertTrue(grid.isRequired(column: 0, row: 4))
        XCTAssertTrue(grid.isRequired(column: 5, row: 0))
    }

    /// The largest hole the grid can leave is half a cell diagonal. That has to
    /// stay within the heatmap kernel's `--sigma-min` (3°), otherwise a fully
    /// "covered" field still contains gaps the kernel would bridge by
    /// extrapolation — the exact failure this protocol exists to prevent.
    func testLargestPossibleGapStaysInsideTheHeatmapKernel() {
        let grid = makeGrid()
        let yawSpacing = 2 * grid.yawAmplitudeDegrees / Double(grid.columns)
        let pitchSpacing = 2 * grid.pitchAmplitudeDegrees / Double(grid.rows)
        let halfDiagonal = (yawSpacing * yawSpacing + pitchSpacing * pitchSpacing)
            .squareRoot() / 2
        XCTAssertLessThanOrEqual(halfDiagonal, 3.1,
                                 "half-cell-diagonal \(halfDiagonal)° exceeds sigma-min 3°")
    }

    /// The field must actually span the range the protocol claims, and not
    /// beyond what the eye can hold fixation through.
    func testFieldExtentSpansTheUsableRange() {
        XCTAssertGreaterThanOrEqual(config.coverageYawAmplitudeDegrees, 24)
        XCTAssertLessThanOrEqual(config.coverageYawAmplitudeDegrees, 30)
        XCTAssertGreaterThanOrEqual(config.coveragePitchAmplitudeDegrees, 17)
        XCTAssertLessThanOrEqual(config.coveragePitchAmplitudeDegrees, 24)
    }

    /// Yaw increases to the right, pitch increases upward (row 0 is the top) —
    /// matching the mirrored virtual head, so the grid reads as a map of where
    /// the head is rather than an abstract meter.
    func testCellMappingOrientation() {
        let grid = makeGrid()
        let centre = grid.cell(yawDegrees: 0, pitchDegrees: 0)
        XCTAssertEqual(centre?.column, 5)
        XCTAssertEqual(centre?.row, 4)

        let right = grid.cell(yawDegrees: 24, pitchDegrees: 0)
        XCTAssertEqual(right?.column, 10)
        XCTAssertEqual(right?.row, 4)

        let left = grid.cell(yawDegrees: -24, pitchDegrees: 0)
        XCTAssertEqual(left?.column, 0)

        let up = grid.cell(yawDegrees: 0, pitchDegrees: 17)
        XCTAssertEqual(up?.row, 0, "positive pitch must map to the TOP row")

        let down = grid.cell(yawDegrees: 0, pitchDegrees: -17)
        XCTAssertEqual(down?.row, 8)
    }

    func testPosesFarOutsideTheFieldAreRejected() {
        let grid = makeGrid()
        XCTAssertNil(grid.cell(yawDegrees: 60, pitchDegrees: 0))
        XCTAssertNil(grid.cell(yawDegrees: 0, pitchDegrees: 40))
        XCTAssertNil(grid.cell(yawDegrees: 0, pitchDegrees: 22))
        XCTAssertNil(grid.cell(yawDegrees: .nan, pitchDegrees: 0))
    }

    /// A slight overshoot still earns credit for the edge cell — without slack
    /// a participant who went 1° too far would get nothing for the effort.
    func testSlightOvershootIsClampedIntoTheEdgeCell() {
        let grid = makeGrid()
        let overshoot = grid.cell(yawDegrees: config.coverageYawAmplitudeDegrees * 1.1,
                                  pitchDegrees: 0)
        XCTAssertEqual(overshoot?.column, grid.columns - 1)
        XCTAssertEqual(overshoot?.row, 4)
    }

    // MARK: - Accumulation

    /// A cell needs a dwell, not a drive-by: one frame must not claim it.
    func testCellNeedsFullSampleCountBeforeItCounts() {
        var grid = makeGrid()
        for i in 1..<config.coverageSamplesPerCell {
            let completed = grid.add(yawDegrees: 0, pitchDegrees: 0)
            XCTAssertFalse(completed, "cell completed early at sample \(i)")
            XCTAssertFalse(grid.isCovered(column: 5, row: 4))
        }
        let completed = grid.add(yawDegrees: 0, pitchDegrees: 0)
        XCTAssertTrue(completed, "the final sample must report completion")
        XCTAssertTrue(grid.isCovered(column: 5, row: 4))
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

    /// In ellipse mode, filling a corner cell must not report completion — it is
    /// bonus data, and a haptic tick there would be misleading.
    func testNonRequiredCellDoesNotReportCompletion() {
        var grid = CoverageGrid(columns: config.coverageColumns,
                                rows: config.coverageRows,
                                yawAmplitudeDegrees: config.coverageYawAmplitudeDegrees,
                                pitchAmplitudeDegrees: config.coveragePitchAmplitudeDegrees,
                                samplesPerCell: config.coverageSamplesPerCell,
                                requiresCorners: false)
        let yaw = -config.coverageYawAmplitudeDegrees * 0.95
        let pitch = config.coveragePitchAmplitudeDegrees * 0.95
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
        XCTAssertEqual(grid.fillFraction(column: 5, row: 4), 0)
        for _ in 0..<(config.coverageSamplesPerCell / 2) {
            _ = grid.add(yawDegrees: 0, pitchDegrees: 0)
        }
        let mid = grid.fillFraction(column: 5, row: 4)
        XCTAssertGreaterThan(mid, 0)
        XCTAssertLessThan(mid, 1)
        for _ in 0..<config.coverageSamplesPerCell {
            _ = grid.add(yawDegrees: 0, pitchDegrees: 0)
        }
        XCTAssertEqual(grid.fillFraction(column: 5, row: 4), 1, "must clamp at 1")
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
        XCTAssertEqual(grid.fillFraction(column: 5, row: 4), 0)
    }

    // MARK: - View payload

    func testFillAndRequiredArraysMatchGridShape() {
        let grid = makeGrid()
        XCTAssertEqual(grid.fillFractions.count, grid.columns * grid.rows)
        XCTAssertEqual(grid.requiredFlags.count, grid.columns * grid.rows)
        // Full-rectangle default: every flag is set, including the corners.
        XCTAssertTrue(grid.requiredFlags.allSatisfy { $0 })
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
