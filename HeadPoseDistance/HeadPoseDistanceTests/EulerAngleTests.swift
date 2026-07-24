import XCTest
import simd
@testable import HeadPoseDistance

/// Quaternion handling, Euler extraction for known rotations, angle wrapping,
/// relative rotation, and the sign-convention layer.
final class EulerAngleTests: XCTestCase {

    private func deg(_ d: Float) -> Float { d * .pi / 180 }

    func testQuaternionNormalizationFromScaledMatrix() {
        // A uniformly scaled rotation matrix must still yield a unit quaternion.
        var m = MathSupport.makeRotationY(radians: 0.6)
        m.columns.0 *= 2
        m.columns.1 *= 2
        m.columns.2 *= 2
        let q = MathSupport.quaternion(of: m)
        XCTAssertNotNil(q)
        XCTAssertEqual(simd_length(q!.vector), 1.0, accuracy: 1e-5)
        XCTAssertEqual(MathSupport.angleBetween(q!, simd_quatf(angle: 0.6, axis: SIMD3<Float>(0, 1, 0))),
                       0, accuracy: 1e-4)
    }

    func testQuaternionRejectsDegenerateMatrix() {
        var m = matrix_identity_float4x4
        m.columns.0 = SIMD4<Float>(0, 0, 0, 0)
        XCTAssertNil(MathSupport.quaternion(of: m))
    }

    func testKnownYawRotation() {
        let q = simd_quatf(angle: deg(30), axis: SIMD3<Float>(0, 1, 0))
        let e = HeadPoseEstimator.eulerAngles(from: q)
        XCTAssertEqual(e.yawDegrees, 30, accuracy: 1e-3)
        XCTAssertEqual(e.pitchDegrees, 0, accuracy: 1e-3)
        XCTAssertEqual(e.rollDegrees, 0, accuracy: 1e-3)
    }

    func testKnownPitchRotation() {
        let q = simd_quatf(angle: deg(20), axis: SIMD3<Float>(1, 0, 0))
        let e = HeadPoseEstimator.eulerAngles(from: q)
        XCTAssertEqual(e.yawDegrees, 0, accuracy: 1e-3)
        XCTAssertEqual(e.pitchDegrees, 20, accuracy: 1e-3)
        XCTAssertEqual(e.rollDegrees, 0, accuracy: 1e-3)
    }

    func testKnownRollRotation() {
        let q = simd_quatf(angle: deg(10), axis: SIMD3<Float>(0, 0, 1))
        let e = HeadPoseEstimator.eulerAngles(from: q)
        XCTAssertEqual(e.yawDegrees, 0, accuracy: 1e-3)
        XCTAssertEqual(e.pitchDegrees, 0, accuracy: 1e-3)
        XCTAssertEqual(e.rollDegrees, 10, accuracy: 1e-3)
    }

    func testCombinedRotationDecomposition() {
        // R = Ry(40°) · Rx(10°) · Rz(5°) must decompose back exactly.
        let qy = simd_quatf(angle: deg(40), axis: SIMD3<Float>(0, 1, 0))
        let qx = simd_quatf(angle: deg(10), axis: SIMD3<Float>(1, 0, 0))
        let qz = simd_quatf(angle: deg(5), axis: SIMD3<Float>(0, 0, 1))
        let e = HeadPoseEstimator.eulerAngles(from: qy * qx * qz)
        XCTAssertEqual(e.yawDegrees, 40, accuracy: 1e-3)
        XCTAssertEqual(e.pitchDegrees, 10, accuracy: 1e-3)
        XCTAssertEqual(e.rollDegrees, 5, accuracy: 1e-3)
    }

    func testNegativeAngles() {
        let qy = simd_quatf(angle: deg(-25), axis: SIMD3<Float>(0, 1, 0))
        XCTAssertEqual(HeadPoseEstimator.eulerAngles(from: qy).yawDegrees, -25, accuracy: 1e-3)
    }

    func testAngleWrapping() {
        XCTAssertEqual(MathSupport.wrapDegrees(190), -170, accuracy: 1e-9)
        XCTAssertEqual(MathSupport.wrapDegrees(-190), 170, accuracy: 1e-9)
        XCTAssertEqual(MathSupport.wrapDegrees(720), 0, accuracy: 1e-9)
        XCTAssertEqual(MathSupport.wrapDegrees(180), -180, accuracy: 1e-9)
        XCTAssertEqual(MathSupport.wrapDegrees(-45), -45, accuracy: 1e-9)
    }

    func testRelativeQuaternionCalculation() {
        // neutral = Ry(10°), current = Ry(35°) -> relative = Ry(25°).
        let neutral = simd_quatf(angle: deg(10), axis: SIMD3<Float>(0, 1, 0))
        let current = simd_quatf(angle: deg(35), axis: SIMD3<Float>(0, 1, 0))
        let relative = MathSupport.relativeRotation(neutral: neutral, current: current)
        let expected = simd_quatf(angle: deg(25), axis: SIMD3<Float>(0, 1, 0))
        XCTAssertEqual(MathSupport.angleBetween(relative, expected), 0, accuracy: 1e-4)
        XCTAssertEqual(HeadPoseEstimator.eulerAngles(from: relative).yawDegrees, 25, accuracy: 1e-3)
    }

    func testRelativeRotationRemovesConstantOffset() {
        // A fixed camera-mount rotation common to neutral and current must
        // cancel out in the relative rotation.
        let mount = simd_quatf(angle: deg(90), axis: SIMD3<Float>(0, 0, 1))
        let head = simd_quatf(angle: deg(15), axis: SIMD3<Float>(0, 1, 0))
        let neutral = mount
        let current = mount * head
        let relative = MathSupport.relativeRotation(neutral: neutral, current: current)
        XCTAssertEqual(MathSupport.angleBetween(relative, head), 0, accuracy: 1e-4)
    }

    func testQuaternionAngularDifference() {
        let q = simd_quatf(angle: deg(33), axis: simd_normalize(SIMD3<Float>(1, 2, 3)))
        let r = simd_quatf(angle: deg(10), axis: SIMD3<Float>(1, 0, 0))
        XCTAssertEqual(MathSupport.angleBetween(q, q * r), Double(deg(10)), accuracy: 1e-4)
        // q and -q are the same rotation.
        let negated = simd_quatf(vector: -q.vector)
        XCTAssertEqual(MathSupport.angleBetween(q, negated), 0, accuracy: 1e-5)
    }

    func testConventionMappingSigns() {
        let raw = EulerAngles(yawDegrees: 10, pitchDegrees: 5, rollDegrees: 3)
        let user = HeadPoseConvention.default.userFacing(from: raw)
        // Defaults: yaw passes through, pitch and roll flip
        // (raw +pitch = nose down, raw +roll = toward left shoulder).
        XCTAssertEqual(user.yawDegrees, 10, accuracy: 1e-9)
        XCTAssertEqual(user.pitchDegrees, -5, accuracy: 1e-9)
        XCTAssertEqual(user.rollDegrees, -3, accuracy: 1e-9)
    }
}
