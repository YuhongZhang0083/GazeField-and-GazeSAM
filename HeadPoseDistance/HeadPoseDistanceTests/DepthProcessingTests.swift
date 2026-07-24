import XCTest
@testable import HeadPoseDistance

/// Valid depth-value filtering and robust ROI aggregation (pure logic; no
/// TrueDepth hardware required).
final class DepthProcessingTests: XCTestCase {

    func testValidDepthValueFiltering() {
        let values: [Float] = [0.40, .nan, .infinity, -.infinity, 0, -1, 0.05, 2.0, 0.45]
        let valid = TrueDepthDistanceEstimator.filterValidDepthValues(values,
                                                                     minMeters: 0.15,
                                                                     maxMeters: 1.0)
        XCTAssertEqual(valid.count, 2)
        XCTAssertEqual(valid[0], 0.40, accuracy: 1e-6)
        XCTAssertEqual(valid[1], 0.45, accuracy: 1e-6)
    }

    func testRobustDepthAggregation() {
        XCTAssertEqual(TrueDepthDistanceEstimator.robustDepth([1, 2, 3])!, 2, accuracy: 1e-9)
        XCTAssertNil(TrueDepthDistanceEstimator.robustDepth([]))

        // Tail outliers must not move the estimate.
        var values = [Double](repeating: 0.40, count: 18)
        values.append(0.16)
        values.append(0.99)
        XCTAssertEqual(TrueDepthDistanceEstimator.robustDepth(values)!, 0.40, accuracy: 1e-9)
    }

    func testTrimmedMedian() {
        // 10% trim on 20 values drops 2 from each end.
        let values = [100.0] + [Double](repeating: 5, count: 18) + [-100.0]
        XCTAssertEqual(Statistics.trimmedMedian(values, trimFraction: 0.1)!, 5, accuracy: 1e-9)
        XCTAssertNil(Statistics.trimmedMedian([], trimFraction: 0.1))
        // Trimming never empties a small array.
        XCTAssertEqual(Statistics.trimmedMedian([7], trimFraction: 0.4)!, 7, accuracy: 1e-9)
    }
}
