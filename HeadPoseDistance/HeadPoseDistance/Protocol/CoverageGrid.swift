import Foundation

/// Tracks which parts of the (yaw, pitch) field have actually been visited,
/// binned into equal cells over an elliptical field.
///
/// ## Why coverage instead of a guided path
///
/// The goal was never "follow a spiral" — it was "sample the field evenly, so
/// `adaptive_kernel_convolution_heatmaps.py` interpolates between measured
/// points instead of extrapolating across gaps it cannot see". A guided path
/// only delivers that if the participant follows it accurately, and it turned
/// out to be an interface people could not read.
///
/// Measuring coverage directly is both simpler to perform and a *stronger*
/// guarantee: a spiral gives uniform density only when tracked perfectly,
/// whereas this requires every cell in the field to hold at least
/// `samplesPerCell` usable samples before the session can finish. The
/// participant moves freely; the grid says what is still missing.
///
/// The field is elliptical for the same reason the spiral was: comfortable
/// eye-in-head range is narrower vertically than horizontally, so cells whose
/// centre falls outside the ellipse are not required (they are still counted
/// if visited — extra data is never discarded).
struct CoverageGrid: Equatable {

    /// Yaw cells (left→right) and pitch cells (top→bottom).
    let columns: Int
    let rows: Int
    let yawAmplitudeDegrees: Double
    let pitchAmplitudeDegrees: Double
    /// Usable samples a cell needs before it counts as covered. At 60 Hz this
    /// is a dwell requirement — it stops a fast swing through a cell from
    /// claiming it with one or two frames.
    let samplesPerCell: Int
    /// How far beyond full amplitude a sample is still accepted (and clamped
    /// into the edge cell), as a fraction of amplitude. Without some slack a
    /// participant who overshoots slightly would get no credit at all.
    let acceptanceMargin: Double

    private(set) var counts: [Int]

    init(columns: Int = 7,
         rows: Int = 5,
         yawAmplitudeDegrees: Double,
         pitchAmplitudeDegrees: Double,
         samplesPerCell: Int,
         acceptanceMargin: Double = 0.15) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        self.yawAmplitudeDegrees = max(1e-6, yawAmplitudeDegrees)
        self.pitchAmplitudeDegrees = max(1e-6, pitchAmplitudeDegrees)
        self.samplesPerCell = max(1, samplesPerCell)
        self.acceptanceMargin = max(0, acceptanceMargin)
        self.counts = [Int](repeating: 0, count: self.columns * self.rows)
    }

    init(config: MeasurementConfig) {
        self.init(columns: config.coverageColumns,
                  rows: config.coverageRows,
                  yawAmplitudeDegrees: config.coverageYawAmplitudeDegrees,
                  pitchAmplitudeDegrees: config.coveragePitchAmplitudeDegrees,
                  samplesPerCell: config.coverageSamplesPerCell)
    }

    // MARK: - Geometry

    private func index(column: Int, row: Int) -> Int { row * columns + column }

    /// Normalized centre of a cell: yaw −1…+1 left→right, pitch +1…−1
    /// top→bottom (row 0 is the top of the display).
    func cellCenter(column: Int, row: Int) -> (u: Double, v: Double) {
        let u = -1 + (2 * Double(column) + 1) / Double(columns)
        let v = 1 - (2 * Double(row) + 1) / Double(rows)
        return (u, v)
    }

    /// Whether a cell lies inside the elliptical field and must be covered.
    func isRequired(column: Int, row: Int) -> Bool {
        let c = cellCenter(column: column, row: row)
        return c.u * c.u + c.v * c.v <= 1.0
    }

    /// Cell a pose falls in, or nil when it is outside the accepted field.
    /// Poses slightly beyond full amplitude are clamped into the edge cell.
    func cell(yawDegrees: Double, pitchDegrees: Double) -> (column: Int, row: Int)? {
        guard yawDegrees.isFinite, pitchDegrees.isFinite else { return nil }
        let uRaw = yawDegrees / yawAmplitudeDegrees
        let vRaw = pitchDegrees / pitchAmplitudeDegrees
        let limit = 1 + acceptanceMargin
        guard uRaw * uRaw + vRaw * vRaw <= limit * limit else { return nil }

        let u = min(max(uRaw, -1), 1)
        let v = min(max(vRaw, -1), 1)
        let column = min(columns - 1, max(0, Int((u + 1) / 2 * Double(columns))))
        let row = min(rows - 1, max(0, Int((1 - v) / 2 * Double(rows))))
        return (column, row)
    }

    // MARK: - Accumulation

    /// Records one usable sample. Returns true when this sample is the one that
    /// completed a **required** cell — the caller uses that to fire a haptic
    /// tick, so progress is felt without looking away from the fixation dot.
    @discardableResult
    mutating func add(yawDegrees: Double, pitchDegrees: Double) -> Bool {
        guard let cell = cell(yawDegrees: yawDegrees, pitchDegrees: pitchDegrees) else {
            return false
        }
        let i = index(column: cell.column, row: cell.row)
        let before = counts[i]
        counts[i] = before + 1
        return before + 1 == samplesPerCell
            && isRequired(column: cell.column, row: cell.row)
    }

    mutating func reset() {
        counts = [Int](repeating: 0, count: columns * rows)
    }

    // MARK: - Progress

    func sampleCount(column: Int, row: Int) -> Int {
        counts[index(column: column, row: row)]
    }

    /// 0…1 how full a cell is — drives partial shading, so the participant can
    /// see a cell filling rather than only its final state.
    func fillFraction(column: Int, row: Int) -> Double {
        min(1, Double(sampleCount(column: column, row: row)) / Double(samplesPerCell))
    }

    func isCovered(column: Int, row: Int) -> Bool {
        sampleCount(column: column, row: row) >= samplesPerCell
    }

    var requiredCellCount: Int {
        var total = 0
        for row in 0..<rows where true {
            for column in 0..<columns where isRequired(column: column, row: row) {
                total += 1
            }
        }
        return total
    }

    var coveredRequiredCellCount: Int {
        var total = 0
        for row in 0..<rows {
            for column in 0..<columns
            where isRequired(column: column, row: row)
                && isCovered(column: column, row: row) {
                total += 1
            }
        }
        return total
    }

    var coveredFraction: Double {
        let required = requiredCellCount
        guard required > 0 else { return 1 }
        return Double(coveredRequiredCellCount) / Double(required)
    }

    /// Row-major fill fractions, top row first — ready for the grid view.
    var fillFractions: [Double] {
        (0..<rows).flatMap { row in
            (0..<columns).map { fillFraction(column: $0, row: row) }
        }
    }

    /// Row-major required flags, top row first.
    var requiredFlags: [Bool] {
        (0..<rows).flatMap { row in
            (0..<columns).map { isRequired(column: $0, row: row) }
        }
    }
}
