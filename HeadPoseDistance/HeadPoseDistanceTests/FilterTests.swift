import XCTest
@testable import HeadPoseDistance

/// Median filter, EMA, and the raw/filtered separation of the chain.
final class FilterTests: XCTestCase {

    func testMedianFilterWindow() {
        var filter = MedianWindowFilter(windowSize: 5)
        XCTAssertEqual(filter.add(1), 1, accuracy: 1e-9)
        XCTAssertEqual(filter.add(2), 1.5, accuracy: 1e-9)
        XCTAssertEqual(filter.add(100), 2, accuracy: 1e-9)      // outlier suppressed
        XCTAssertEqual(filter.add(3), 2.5, accuracy: 1e-9)
        XCTAssertEqual(filter.add(2), 2, accuracy: 1e-9)
        // Window slides: [2, 100, 3, 2, 4] -> median 3.
        XCTAssertEqual(filter.add(4), 3, accuracy: 1e-9)
        XCTAssertEqual(filter.currentWindowCount, 5)
    }

    func testMedianFilterReset() {
        var filter = MedianWindowFilter(windowSize: 3)
        _ = filter.add(5)
        filter.reset()
        XCTAssertEqual(filter.currentWindowCount, 0)
        XCTAssertEqual(filter.add(7), 7, accuracy: 1e-9)
    }

    func testExponentialMovingAverage() {
        var ema = ExponentialMovingAverageFilter(alpha: 0.2)
        XCTAssertEqual(ema.add(1), 1, accuracy: 1e-9)            // seeds with first value
        XCTAssertEqual(ema.add(2), 1.2, accuracy: 1e-9)          // 0.2*2 + 0.8*1

        var half = ExponentialMovingAverageFilter(alpha: 0.5)
        XCTAssertEqual(half.add(1), 1, accuracy: 1e-9)
        XCTAssertEqual(half.add(3), 2, accuracy: 1e-9)
    }

    func testPipelineKeepsRawAndFilteredSeparate() {
        var pipeline = DistanceFilterPipeline(config: .default)   // median 5, alpha 0.2
        pipeline.add(raw: 0.5)
        pipeline.add(raw: 0.5)
        pipeline.add(raw: 0.5)
        pipeline.add(raw: 0.6)
        // Raw shows the new value; the median window still reports 0.5.
        XCTAssertEqual(pipeline.lastRaw!, 0.6, accuracy: 1e-9)
        XCTAssertEqual(pipeline.lastMedian!, 0.5, accuracy: 1e-9)
        XCTAssertEqual(pipeline.lastEMA!, 0.5, accuracy: 1e-9)
    }

    func testStatisticsHelpers() {
        XCTAssertNil(Statistics.median([]))
        XCTAssertEqual(Statistics.median([1, 3, 2])!, 2, accuracy: 1e-9)
        XCTAssertEqual(Statistics.median([1, 2, 3, 4])!, 2.5, accuracy: 1e-9)
        XCTAssertEqual(Statistics.mean([1, 2, 3])!, 2, accuracy: 1e-9)
        XCTAssertEqual(Statistics.standardDeviation([1, 2, 3, 4, 5])!,
                       1.58113883, accuracy: 1e-6)
        XCTAssertNil(Statistics.standardDeviation([1]))
    }
}
