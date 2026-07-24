import XCTest
import simd
@testable import HeadPoseDistance

/// Matrix inversion/composition, camera-relative face transform, translation
/// extraction, distance calculations, and the screen-offset arithmetic.
final class TransformMathTests: XCTestCase {

    private func assertEqual(_ a: simd_float4x4, _ b: simd_float4x4,
                             accuracy: Float, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        let ac = [a.columns.0, a.columns.1, a.columns.2, a.columns.3]
        let bc = [b.columns.0, b.columns.1, b.columns.2, b.columns.3]
        for c in 0..<4 {
            for r in 0..<4 {
                XCTAssertEqual(ac[c][r], bc[c][r], accuracy: accuracy,
                               "\(message) mismatch at col \(c) row \(r)",
                               file: file, line: line)
            }
        }
    }

    func testMatrixInversionComposition() {
        let m = simd_mul(MathSupport.makeTranslation(SIMD3<Float>(1, -2, 3)),
                         MathSupport.makeRotationY(radians: 0.7))
        assertEqual(simd_mul(m, m.inverse), matrix_identity_float4x4, accuracy: 1e-5)
        assertEqual(simd_mul(m.inverse, m), matrix_identity_float4x4, accuracy: 1e-5)
    }

    func testCameraFromFaceRecoversKnownRelativeTransform() {
        // worldFromFace = worldFromCamera * expected  =>
        // cameraFromFace must equal expected.
        let worldFromCamera = simd_mul(MathSupport.makeTranslation(SIMD3<Float>(0.5, 1.0, -0.3)),
                                       MathSupport.makeRotationY(radians: 0.5))
        let expected = simd_mul(MathSupport.makeTranslation(SIMD3<Float>(0.1, -0.05, -0.4)),
                                MathSupport.makeRotationZ(radians: 0.2))
        let worldFromFace = simd_mul(worldFromCamera, expected)

        let computed = MathSupport.cameraFromFace(worldFromCamera: worldFromCamera,
                                                  worldFromFace: worldFromFace)
        assertEqual(computed, expected, accuracy: 1e-5)
    }

    func testTranslationExtraction() {
        let m = MathSupport.makeTranslation(SIMD3<Float>(1, 2, 3))
        let t = MathSupport.translation(of: m)
        XCTAssertEqual(t.x, 1, accuracy: 1e-6)
        XCTAssertEqual(t.y, 2, accuracy: 1e-6)
        XCTAssertEqual(t.z, 3, accuracy: 1e-6)
    }

    func testEuclideanDistanceAndForwardDepth() {
        // Camera at origin; face at (3, 4, 12): 3-4-12-13 quadruple.
        let pose = FaceTransformCalculator.computePose(
            worldFromCamera: matrix_identity_float4x4,
            worldFromFace: MathSupport.makeTranslation(SIMD3<Float>(3, 4, 12)))
        XCTAssertNotNil(pose)
        XCTAssertEqual(pose!.forwardDepthMeters, 12, accuracy: 1e-5)
        XCTAssertEqual(pose!.headReferenceDistanceMeters, 13, accuracy: 1e-5)
    }

    func testForwardDepthUsesAbsoluteZ() {
        // ARKit camera looks along -Z, so faces sit at negative z.
        let pose = FaceTransformCalculator.computePose(
            worldFromCamera: matrix_identity_float4x4,
            worldFromFace: MathSupport.makeTranslation(SIMD3<Float>(0, 0, -0.45)))
        XCTAssertEqual(pose!.forwardDepthMeters, 0.45, accuracy: 1e-6)
        XCTAssertEqual(pose!.headReferenceDistanceMeters, 0.45, accuracy: 1e-6)
    }

    func testComputePoseRejectsNonFiniteTransforms() {
        var bad = matrix_identity_float4x4
        bad.columns.3.x = Float.nan
        XCTAssertNil(FaceTransformCalculator.computePose(worldFromCamera: matrix_identity_float4x4,
                                                         worldFromFace: bad))
    }

    func testScreenOffsetDistanceCalculation() {
        XCTAssertEqual(FaceTransformCalculator.estimatedScreenToFaceMeters(
            trueDepthFaceSurfaceMeters: 0.45,
            cameraBehindScreenOffsetMeters: 0.02), 0.43, accuracy: 1e-9)
        // Offset calibration: offset = median camera depth − reference.
        XCTAssertEqual(ScreenDistanceCalibrator.computeOffset(
            medianCameraDepthMeters: 0.45,
            referenceScreenDistanceMeters: 0.43), 0.02, accuracy: 1e-9)
    }

    func testFlattenIsColumnMajor() {
        let m = MathSupport.makeTranslation(SIMD3<Float>(7, 8, 9))
        let flat = FaceTransformCalculator.flatten(m)
        XCTAssertEqual(flat.count, 16)
        // Translation lives in the last column (elements 12..14).
        XCTAssertEqual(flat[12], 7)
        XCTAssertEqual(flat[13], 8)
        XCTAssertEqual(flat[14], 9)
        XCTAssertEqual(flat[15], 1)
    }
}
