import XCTest
import simd
@testable import HeadPoseDistance

/// Pins the mirror-convention mapping from user-facing yaw/pitch/roll onto
/// the virtual head's rotation. SceneKit view space: +X right, +Y up,
/// +Z toward the viewer; the head's neutral forward is +Z.
final class VirtualHeadOrientationTests: XCTestCase {

    private let accuracy: Float = 1e-5

    func testNeutralPoseIsIdentity() {
        let forward = VirtualHeadOrientation.forwardVector(
            yawDegrees: 0, pitchDegrees: 0, rollDegrees: 0)
        XCTAssertEqual(forward.x, 0, accuracy: accuracy)
        XCTAssertEqual(forward.y, 0, accuracy: accuracy)
        XCTAssertEqual(forward.z, 1, accuracy: accuracy)
    }

    /// Mirror: the participant turns right → the on-screen head's face turns
    /// toward the viewer's right (+X).
    func testYawRightTurnsHeadTowardViewerRight() {
        let forward = VirtualHeadOrientation.forwardVector(
            yawDegrees: 90, pitchDegrees: 0, rollDegrees: 0)
        XCTAssertEqual(forward.x, 1, accuracy: accuracy)
        XCTAssertEqual(forward.z, 0, accuracy: accuracy)

        let slight = VirtualHeadOrientation.forwardVector(
            yawDegrees: 20, pitchDegrees: 0, rollDegrees: 0)
        XCTAssertGreaterThan(slight.x, 0)
    }

    func testPitchUpTiltsHeadUp() {
        let forward = VirtualHeadOrientation.forwardVector(
            yawDegrees: 0, pitchDegrees: 90, rollDegrees: 0)
        XCTAssertEqual(forward.y, 1, accuracy: accuracy)
        XCTAssertEqual(forward.z, 0, accuracy: accuracy)

        let slight = VirtualHeadOrientation.forwardVector(
            yawDegrees: 0, pitchDegrees: 15, rollDegrees: 0)
        XCTAssertGreaterThan(slight.y, 0)
        XCTAssertGreaterThan(slight.z, 0, "a slight tilt keeps facing the viewer")
    }

    /// Mirror: roll toward the participant's right shoulder tips the head's
    /// up-vector toward the viewer's right (+X).
    func testRollTipsUpVectorMirrorwise() {
        let up = VirtualHeadOrientation.upVector(
            yawDegrees: 0, pitchDegrees: 0, rollDegrees: 30)
        XCTAssertGreaterThan(up.x, 0)
        XCTAssertGreaterThan(up.y, 0.5, "30° roll keeps the head mostly upright")
    }

    func testDiagonalCombinesYawAndPitch() {
        let forward = VirtualHeadOrientation.forwardVector(
            yawDegrees: 20, pitchDegrees: 20, rollDegrees: 0)
        XCTAssertGreaterThan(forward.x, 0)
        XCTAssertGreaterThan(forward.y, 0)
        XCTAssertGreaterThan(forward.z, 0.8, "20° angles stay mostly frontal")
    }

    func testQuaternionIsAlwaysUnit() {
        for (yaw, pitch, roll) in [(0.0, 0.0, 0.0), (45.0, -30.0, 15.0),
                                   (-90.0, 10.0, -40.0)] {
            let q = VirtualHeadOrientation.quaternion(
                yawDegrees: yaw, pitchDegrees: pitch, rollDegrees: roll)
            XCTAssertEqual(simd_length(q.vector), 1, accuracy: 1e-4)
        }
    }

    func testNonFiniteInputYieldsIdentity() {
        let q = VirtualHeadOrientation.quaternion(
            yawDegrees: .nan, pitchDegrees: 10, rollDegrees: .infinity)
        let forward = q.act(SIMD3<Float>(0, 0, 1))
        XCTAssertEqual(forward.z, 1, accuracy: accuracy)
    }

    /// The head node must exist and carry a nose (forward indicator) — the
    /// visualization is generic geometry, not ARKit face geometry.
    func testHeadNodeIsGenericWithForwardIndicator() {
        let head = VirtualHeadView.makeHeadNode()
        XCTAssertEqual(head.name, "head")
        XCTAssertNotNil(head.childNode(withName: "nose", recursively: false))
        XCTAssertGreaterThanOrEqual(head.childNodes.count, 3)
    }
}
