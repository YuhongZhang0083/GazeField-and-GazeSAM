import XCTest
@testable import HeadPoseDistance

/// CSV formatting and JSON encoding/decoding.
final class ExportTests: XCTestCase {

    private func makeSample() -> MeasurementSample {
        MeasurementSample(
            timestampUnix: 1700000000.5,
            arFrameTimestamp: 123.456,
            sessionElapsedSeconds: 2.5,
            protocolPhase: "up",
            cameraTransform: Array(repeating: Float(0), count: 16),
            faceAnchorTransform: Array(repeating: Float(0), count: 16),
            cameraFromFaceTransform: Array(repeating: Float(0), count: 16),
            translationX: 0.01,
            translationY: -0.02,
            translationZ: -0.4,
            forwardDepthMeters: 0.4,
            headReferenceDistanceMeters: 0.400625,
            trueDepthSurfaceRawMeters: 0.412345,
            trueDepthSurfaceMedianFilteredMeters: 0.4125,
            trueDepthSurfaceEMAFilteredMeters: 0.4130,
            estimatedScreenToFaceMeters: 0.4023,
            distanceDeviationFromBaselineMeters: 0.001,
            quaternionX: 0.01, quaternionY: 0.02, quaternionZ: 0.03, quaternionW: 0.999,
            rawYawDegrees: 1.5, rawPitchDegrees: -2.5, rawRollDegrees: 88.0,
            relativeYawDegrees: 0.5, relativePitchDegrees: 12.0, relativeRollDegrees: -0.3,
            headAngularVelocityDegPerSec: 15.0,
            phoneRotationRateMagnitudeRadPerSec: 0.01,
            phoneAccelerationMagnitudeG: 0.005,
            phoneAttitudeChangeDegrees: 0.2,
            trueDepthValidPixelCount: 250,
            trueDepthValidPixelRatio: 0.87,
            trackingValid: true,
            phoneStable: true,
            distanceStable: true,
            sampleValid: true,
            confidence: 0.95,
            rejectionReasons: [])
    }

    // MARK: - CSV

    func testCSVHeaderMatchesRowWidth() {
        let row = CSVExporter.row(for: makeSample())
        XCTAssertEqual(row.count, CSVExporter.header.count)
    }

    func testCSVFormatting() {
        XCTAssertEqual(CSVExporter.format(nil as Double?), "")
        XCTAssertEqual(CSVExporter.format(0.4), "0.400000")
        XCTAssertEqual(CSVExporter.format(Double.nan), "")
        XCTAssertEqual(CSVExporter.format(true), "1")
        XCTAssertEqual(CSVExporter.format(false), "0")
        XCTAssertEqual(CSVExporter.format(nil as Int?), "")
        XCTAssertEqual(CSVExporter.format(42 as Int?), "42")
    }

    func testCSVStringStructure() {
        var rejected = makeSample()
        rejected.sampleValid = false
        rejected.confidence = 0
        rejected.rejectionReasons = ["face_not_tracked", "phone_movement_excessive"]

        let csv = CSVExporter.csvString(samples: [makeSample(), rejected])
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines[0], Substring(CSVExporter.header.joined(separator: ",")))
        // Header + 2 rows + trailing newline.
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[3], "")

        XCTAssertTrue(lines[1].contains("0.412345"))
        XCTAssertTrue(lines[1].contains(",up,"))
        XCTAssertTrue(lines[2].contains("face_not_tracked;phone_movement_excessive"))

        // Every row must match the header width.
        XCTAssertEqual(lines[1].split(separator: ",", omittingEmptySubsequences: false).count,
                       CSVExporter.header.count)
        XCTAssertEqual(lines[2].split(separator: ",", omittingEmptySubsequences: false).count,
                       CSVExporter.header.count)
    }

    // MARK: - JSON

    func testJSONRoundTrip() throws {
        var metadata = SessionMetadata()
        metadata.screenWidthPoints = 393
        metadata.screenHeightPoints = 852
        metadata.screenScale = 3
        metadata.dotCenterXPoints = 196.5
        metadata.dotCenterYPoints = 426
        metadata.durationSeconds = 25.2
        metadata.trueDepthSurfaceAvailable = true
        metadata.cameraBehindScreenOffsetMeters = 0.005
        metadata.screenOffsetCalibrated = true

        let neutral = NeutralPose(quaternion: [0, 0, 0, 1],
                                  translation: [0.0, 0.0, -0.4],
                                  rawYawDegrees: 0.1,
                                  rawPitchDegrees: -0.2,
                                  rawRollDegrees: 89.9,
                                  baselineHeadReferenceDistanceMeters: 0.4,
                                  baselineSurfaceDistanceMeters: 0.41,
                                  capturedAt: Date(timeIntervalSince1970: 1700000000),
                                  acceptedSampleCount: 55)

        let samples = [makeSample()]
        let summary = SessionSummary.compute(accepted: samples, rejected: [],
                                             durationSeconds: 25.2)
        let document = SessionExportDocument(metadata: metadata,
                                             configuration: .default,
                                             headPoseConvention: .default,
                                             neutralCalibration: neutral,
                                             summary: summary,
                                             samples: samples,
                                             rejectedSamples: nil)

        let data = try JSONExporter.data(for: document)
        XCTAssertFalse(data.isEmpty)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SessionExportDocument.self, from: data)

        XCTAssertEqual(decoded.metadata.sessionID, metadata.sessionID)
        XCTAssertEqual(decoded.metadata.dotCenterXPoints, 196.5, accuracy: 1e-9)
        XCTAssertEqual(decoded.neutralCalibration, neutral)
        XCTAssertEqual(decoded.samples.count, 1)
        XCTAssertEqual(decoded.samples[0].trueDepthSurfaceRawMeters!, 0.412345, accuracy: 1e-9)
        XCTAssertEqual(decoded.configuration, MeasurementConfig.default)
        XCTAssertNil(decoded.rejectedSamples)
    }

    // MARK: - Summary

    func testSessionSummaryCompute() {
        var a = makeSample()
        a.relativeYawDegrees = 20
        var b = makeSample()
        b.relativeYawDegrees = -35
        b.phoneStable = false
        var rejected = makeSample()
        rejected.sampleValid = false
        rejected.rejectionReasons = ["face_not_tracked"]

        let summary = SessionSummary.compute(accepted: [a, b], rejected: [rejected],
                                             durationSeconds: 10)
        XCTAssertEqual(summary.totalSamples, 3)
        XCTAssertEqual(summary.acceptedSamples, 2)
        XCTAssertEqual(summary.rejectedSamples, 1)
        XCTAssertEqual(summary.meanSamplingRateHz, 0.3, accuracy: 1e-9)
        XCTAssertEqual(summary.maxAbsoluteRelativeYawDegrees!, 35, accuracy: 1e-9)
        XCTAssertEqual(summary.rejectionReasonCounts["face_not_tracked"], 1)
        // 2 of 3 samples phone-stable.
        XCTAssertEqual(summary.phoneStablePercentage, 100.0 * 2 / 3, accuracy: 1e-6)
        XCTAssertEqual(summary.validTrueDepthPercentage, 100, accuracy: 1e-6)
    }
}
