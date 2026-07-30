import XCTest
@testable import HeadPoseDistance

/// Tests for the coverage grid — the thing that now *defines* whether a
/// free-exploration session produced usable gaze-field data.
final class CoverageGridTests: XCTestCase {

    private let config = MeasurementConfig.default
    private func makeGrid() -> CoverageGrid { CoverageGrid(config: config) }

    // MARK: - Geometry

    /// Every cell inside the reachability cap is required; only cells past it
    /// are exempt. At ±32° with a 34° cap that is 249 of 289.
    func testRequiredFieldIsEverythingInsideTheReachabilityCap() {
        let grid = makeGrid()
        XCTAssertEqual(grid.columns * grid.rows, 289)
        XCTAssertEqual(grid.requiredCellCount, 249)
        for row in 0..<grid.rows {
            for column in 0..<grid.columns {
                let inside = grid.cellCombinedDegrees(column: column, row: row)
                    <= config.coverageMaxCombinedDegrees
                XCTAssertEqual(grid.isRequired(column: column, row: row), inside,
                               "cell (\(column), \(row)) requirement must follow the cap")
            }
        }
        // The box corners demand more rotation than the eye has while fixating,
        // so they must NOT be required.
        XCTAssertGreaterThan(grid.cellCombinedDegrees(column: 0, row: 0), 40)
        XCTAssertFalse(grid.isRequired(column: 0, row: 0))
    }

    /// The widened field must be a strict superset of the previous ±25° square
    /// field: nothing that used to be required may drop out. Reach along each
    /// axis grows from 23.1° to 30.1°.
    func testWidenedFieldStrictlyContainsThePreviousField() {
        let grid = makeGrid()
        let previous = CoverageGrid(columns: 13, rows: 13,
                                    yawAmplitudeDegrees: 25, pitchAmplitudeDegrees: 25,
                                    samplesPerCell: 8,
                                    maxCombinedDegrees: .greatestFiniteMagnitude)
        for row in 0..<previous.rows {
            for column in 0..<previous.columns
            where previous.isRequired(column: column, row: row) {
                let old = previous.cellCombinedDegrees(column: column, row: row)
                XCTAssertLessThanOrEqual(old, config.coverageMaxCombinedDegrees,
                                         "old required cell at \(old)° must still be inside the cap")
            }
        }

        func axisReach(_ g: CoverageGrid) -> Double {
            g.cellCenter(column: g.columns - 1, row: g.rows / 2).u * g.yawAmplitudeDegrees
        }
        XCTAssertGreaterThan(axisReach(grid), axisReach(previous) + 5,
                             "the point of widening is materially more axis reach")
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

    /// Raising the cap out of the way requires the full rectangle again.
    func testUncappedGridRequiresEveryCell() {
        let grid = CoverageGrid(columns: 17, rows: 17,
                                yawAmplitudeDegrees: 32, pitchAmplitudeDegrees: 32,
                                samplesPerCell: 8, maxCombinedDegrees: 1000)
        XCTAssertEqual(grid.requiredCellCount, grid.columns * grid.rows)
        XCTAssertTrue(grid.isRequired(column: 0, row: 0))
    }

    /// The cap may only trim diagonals — it must keep the full reach along each
    /// axis, since clipping the axes would undo the widening.
    func testCapDoesNotTrimTheAxes() {
        let grid = makeGrid()
        let mid = grid.rows / 2
        for index in 0..<grid.columns {
            XCTAssertTrue(grid.isRequired(column: index, row: mid),
                          "the full horizontal axis must stay required")
            XCTAssertTrue(grid.isRequired(column: mid, row: index),
                          "the full vertical axis must stay required")
        }
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
        for amplitude in [config.coverageYawAmplitudeDegrees,
                          config.coveragePitchAmplitudeDegrees] {
            XCTAssertGreaterThanOrEqual(amplitude, 30)
            // Past ~35° ARKit starts losing the face and fixation breaks, so a
            // wider field would only add cells nobody can reach.
            XCTAssertLessThanOrEqual(amplitude, 35)
        }
    }

    /// Vertical extent must equal horizontal: an earlier asymmetric field
    /// (±25 × ±18) simply left the upper and lower FOV unmeasured, which is the
    /// same extrapolation problem as the excluded corners.
    func testFieldIsSquareSoVerticalExtentMatchesHorizontal() {
        XCTAssertEqual(config.coverageYawAmplitudeDegrees,
                       config.coveragePitchAmplitudeDegrees, accuracy: 1e-9)
        let grid = makeGrid()
        XCTAssertEqual(grid.columns, grid.rows,
                       "square field needs a square grid for isotropic cells")

        // Reaching the same angle up as right must land the same distance from
        // the centre cell in each axis.
        let angle = config.coverageYawAmplitudeDegrees * 0.9
        guard let right = grid.cell(yawDegrees: angle, pitchDegrees: 0),
              let up = grid.cell(yawDegrees: 0, pitchDegrees: angle) else {
            return XCTFail("both extremes must be inside the field")
        }
        let centre = (column: grid.columns / 2, row: grid.rows / 2)
        XCTAssertEqual(right.column - centre.column, centre.row - up.row,
                       "the field must extend as far up as it does right")
    }

    /// Odd grid dimensions put a cell CENTRE at neutral. An even grid puts a
    /// boundary there, so the resting pose straddles two cells and the
    /// current-cell marker flickers between them.
    func testNeutralLandsOnACellCentreNotABoundary() {
        let grid = makeGrid()
        XCTAssertEqual(grid.columns % 2, 1)
        XCTAssertEqual(grid.rows % 2, 1)
        let centre = grid.cell(yawDegrees: 0, pitchDegrees: 0)
        XCTAssertEqual(centre?.column, grid.columns / 2)
        XCTAssertEqual(centre?.row, grid.rows / 2)
        let exact = grid.cellCenter(column: grid.columns / 2, row: grid.rows / 2)
        XCTAssertEqual(exact.u, 0, accuracy: 1e-12)
        XCTAssertEqual(exact.v, 0, accuracy: 1e-12)
    }

    /// The realistic failure mode is losing the bottom row: downward head pitch
    /// needs the eye to roll up, its most limited direction. The completion
    /// threshold must absorb that.
    func testMissingTheEntireBottomRowStillCompletes() {
        var grid = makeGrid()
        for row in 0..<(grid.rows - 1) {
            for column in 0..<grid.columns where grid.isRequired(column: column, row: row) {
                let centre = grid.cellCenter(column: column, row: row)
                for _ in 0..<grid.samplesPerCell {
                    _ = grid.add(yawDegrees: centre.u * grid.yawAmplitudeDegrees,
                                 pitchDegrees: centre.v * grid.pitchAmplitudeDegrees)
                }
            }
        }
        XCTAssertGreaterThanOrEqual(grid.coveredFraction, config.coverageCompletionFraction,
                                    "threshold must tolerate losing a whole row")
    }

    /// Yaw increases to the right, pitch increases upward (row 0 is the top) —
    /// matching the mirrored virtual head, so the grid reads as a map of where
    /// the head is rather than an abstract meter.
    func testCellMappingOrientation() {
        let grid = makeGrid()
        let centre = grid.cell(yawDegrees: 0, pitchDegrees: 0)
        XCTAssertEqual(centre?.column, 8)
        XCTAssertEqual(centre?.row, 8)

        let right = grid.cell(yawDegrees: 31, pitchDegrees: 0)
        XCTAssertEqual(right?.column, 16)
        XCTAssertEqual(right?.row, 8)

        let left = grid.cell(yawDegrees: -31, pitchDegrees: 0)
        XCTAssertEqual(left?.column, 0)

        let up = grid.cell(yawDegrees: 0, pitchDegrees: 31)
        XCTAssertEqual(up?.row, 0, "positive pitch must map to the TOP row")

        let down = grid.cell(yawDegrees: 0, pitchDegrees: -31)
        XCTAssertEqual(down?.row, 16)
    }

    func testPosesFarOutsideTheFieldAreRejected() {
        let grid = makeGrid()
        XCTAssertNil(grid.cell(yawDegrees: 70, pitchDegrees: 0))
        XCTAssertNil(grid.cell(yawDegrees: 0, pitchDegrees: 40))
        XCTAssertNil(grid.cell(yawDegrees: 0, pitchDegrees: 38))
        XCTAssertNil(grid.cell(yawDegrees: .nan, pitchDegrees: 0))
    }

    /// A slight overshoot still earns credit for the edge cell — without slack
    /// a participant who went 1° too far would get nothing for the effort.
    func testSlightOvershootIsClampedIntoTheEdgeCell() {
        let grid = makeGrid()
        let overshoot = grid.cell(yawDegrees: config.coverageYawAmplitudeDegrees * 1.1,
                                  pitchDegrees: 0)
        XCTAssertEqual(overshoot?.column, grid.columns - 1)
        XCTAssertEqual(overshoot?.row, 8)
    }

    // MARK: - Accumulation

    /// A cell needs a dwell, not a drive-by: one frame must not claim it.
    func testCellNeedsFullSampleCountBeforeItCounts() {
        var grid = makeGrid()
        for i in 1..<config.coverageSamplesPerCell {
            let completed = grid.add(yawDegrees: 0, pitchDegrees: 0)
            XCTAssertFalse(completed, "cell completed early at sample \(i)")
            XCTAssertFalse(grid.isCovered(column: 8, row: 8))
        }
        let completed = grid.add(yawDegrees: 0, pitchDegrees: 0)
        XCTAssertTrue(completed, "the final sample must report completion")
        XCTAssertTrue(grid.isCovered(column: 8, row: 8))
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

    /// Filling a cell past the reachability cap must not report completion — it
    /// is bonus data, and a haptic tick there would be misleading.
    func testNonRequiredCellDoesNotReportCompletion() {
        var grid = makeGrid()
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
        XCTAssertEqual(grid.fillFraction(column: 8, row: 8), 0)
        for _ in 0..<(config.coverageSamplesPerCell / 2) {
            _ = grid.add(yawDegrees: 0, pitchDegrees: 0)
        }
        let mid = grid.fillFraction(column: 8, row: 8)
        XCTAssertGreaterThan(mid, 0)
        XCTAssertLessThan(mid, 1)
        for _ in 0..<config.coverageSamplesPerCell {
            _ = grid.add(yawDegrees: 0, pitchDegrees: 0)
        }
        XCTAssertEqual(grid.fillFraction(column: 8, row: 8), 1, "must clamp at 1")
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
        XCTAssertEqual(grid.fillFraction(column: 8, row: 8), 0)
    }

    // MARK: - View payload

    func testFillAndRequiredArraysMatchGridShape() {
        let grid = makeGrid()
        XCTAssertEqual(grid.fillFractions.count, grid.columns * grid.rows)
        XCTAssertEqual(grid.requiredFlags.count, grid.columns * grid.rows)
        // Flags follow the reachability cap: everything inside it is set, the
        // unreachable box corners are not.
        XCTAssertEqual(grid.requiredFlags.filter { $0 }.count, grid.requiredCellCount)
        XCTAssertFalse(grid.requiredFlags[0], "the top-left box corner is past the cap")
        XCTAssertTrue(grid.requiredFlags[grid.rows / 2 * grid.columns + grid.columns / 2],
                      "the centre cell is always required")
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
