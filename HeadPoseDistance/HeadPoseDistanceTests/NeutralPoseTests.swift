import XCTest
import simd
@testable import HeadPoseDistance

/// Neutral-pose aggregation: quaternion-aware averaging, robust baselines,
/// and the acceptance gates.
final class NeutralPoseTests: XCTestCase {

    private func deg(_ d: Float) -> Float { d * .pi / 180 }

    private func makeCandidates(count: Int = 40,
                                quaternion: (Int) -> simd_quatf = { _ in simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)) },
                                distance: (Int) -> Double = { _ in 0.4 },
                                surface: (Int) -> Double? = { _ in 0.42 },
                                velocity: Double = 1.0,
                                phoneStable: (Int) -> Bool = { _ in true }) -> [NeutralPoseCalibrator.Candidate] {
        (0..<count).map { i in
            NeutralPoseCalibrator.Candidate(
                quaternion: quaternion(i),
                translation: SIMD3<Float>(0.01, -0.02, -Float(distance(i))),
                headReferenceDistanceMeters: distance(i),
                surfaceDistanceMeters: surface(i),
                angularVelocityDegPerSec: velocity,
                phoneStable: phoneStable(i),
                timestamp: Double(i) / 60.0)
        }
    }

    func testSuccessfulAggregation() {
        // Small yaw jitter around 5°; result must be ≈ Ry(5°).
        let base = simd_quatf(angle: deg(5), axis: SIMD3<Float>(0, 1, 0))
        let candidates = makeCandidates(quaternion: { i in
            simd_quatf(angle: deg(5) + deg(0.3) * Float(i % 2 == 0 ? 1 : -1),
                       axis: SIMD3<Float>(0, 1, 0))
        })
        let result = NeutralPoseCalibrator.aggregate(candidates: candidates, config: .default)
        guard case .success(let pose) = result else {
            return XCTFail("Expected success, got \(result)")
        }
        XCTAssertEqual(MathSupport.angleBetween(pose.simdQuaternion, base), 0,
                       accuracy: MathSupport.radians(0.5))
        XCTAssertEqual(pose.baselineHeadReferenceDistanceMeters, 0.4, accuracy: 1e-9)
        XCTAssertEqual(pose.baselineSurfaceDistanceMeters!, 0.42, accuracy: 1e-9)
        XCTAssertEqual(pose.acceptedSampleCount, 40)
    }

    func testQuaternionSignFlipsAreAligned() {
        // Alternating q and -q (identical rotations) must not cancel out.
        let base = simd_quatf(angle: deg(5), axis: SIMD3<Float>(0, 1, 0))
        let candidates = makeCandidates(quaternion: { i in
            i % 2 == 0 ? base : simd_quatf(vector: -base.vector)
        })
        let result = NeutralPoseCalibrator.aggregate(candidates: candidates, config: .default)
        guard case .success(let pose) = result else {
            return XCTFail("Expected success, got \(result)")
        }
        XCTAssertEqual(MathSupport.angleBetween(pose.simdQuaternion, base), 0, accuracy: 1e-4)
    }

    func testAverageQuaternionDirectly() {
        let a = simd_quatf(angle: deg(4), axis: SIMD3<Float>(0, 1, 0))
        let b = simd_quatf(angle: deg(6), axis: SIMD3<Float>(0, 1, 0))
        let avg = MathSupport.averageQuaternion([a, b])!
        let expected = simd_quatf(angle: deg(5), axis: SIMD3<Float>(0, 1, 0))
        XCTAssertEqual(MathSupport.angleBetween(avg, expected), 0, accuracy: 1e-4)
        XCTAssertNil(MathSupport.averageQuaternion([]))
    }

    func testTooFewSamplesFails() {
        let result = NeutralPoseCalibrator.aggregate(candidates: makeCandidates(count: 10),
                                                     config: .default)
        XCTAssertEqual(result, .failure(.tooFewSamples(10)))
    }

    func testHeadMovingFails() {
        let candidates = makeCandidates(velocity: 50)   // above 10 °/s threshold
        let result = NeutralPoseCalibrator.aggregate(candidates: candidates, config: .default)
        XCTAssertEqual(result, .failure(.headMoving))
    }

    func testDistanceUnstableFails() {
        let candidates = makeCandidates(distance: { i in i % 2 == 0 ? 0.35 : 0.45 })
        let result = NeutralPoseCalibrator.aggregate(candidates: candidates, config: .default)
        XCTAssertEqual(result, .failure(.distanceUnstable))
    }

    func testPhoneMovingFails() {
        let candidates = makeCandidates(phoneStable: { i in i % 2 == 0 })   // 50% < 80%
        let result = NeutralPoseCalibrator.aggregate(candidates: candidates, config: .default)
        XCTAssertEqual(result, .failure(.phoneMoving))
    }

    func testSurfaceBaselineRequiresMajorityCoverage() {
        // Only 25% of the window has surface depth -> no surface baseline.
        let candidates = makeCandidates(surface: { i in i % 4 == 0 ? 0.42 : nil })
        let result = NeutralPoseCalibrator.aggregate(candidates: candidates, config: .default)
        guard case .success(let pose) = result else {
            return XCTFail("Expected success, got \(result)")
        }
        XCTAssertNil(pose.baselineSurfaceDistanceMeters)
    }
}
