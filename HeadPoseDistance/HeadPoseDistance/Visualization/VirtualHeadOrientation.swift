import Foundation
import simd

/// Maps user-facing neutral-relative Euler angles onto a rotation for the
/// virtual head node, using **mirror semantics**: the virtual head faces the
/// viewer (+Z toward the camera) and moves like a reflection, which is what
/// people intuitively expect from an on-screen avatar of themselves.
///
/// SceneKit view space: +X right, +Y up, +Z toward the viewer.
/// User convention (from `HeadPoseConvention`): yaw + = head turned to the
/// participant's right, pitch + = head rotated up.
///
/// Mirror mapping (verified by unit tests on the forward/up vectors):
/// - yaw +   → head's forward vector gains +X (turns toward the viewer's
///             right, same side as the participant's right in a mirror)
/// - pitch + → forward vector gains +Y (tilts up)
/// - roll +  → head's up vector gains +X (tilts toward the participant's
///             right shoulder, mirrored)
///
/// Roll's user-facing sign is one of the conventions still awaiting physical
/// verification; if it reads backwards on hardware fix `HeadPoseConvention`,
/// not this file.
enum VirtualHeadOrientation {

    /// Rotation for the head node. Non-finite inputs yield identity.
    static func quaternion(yawDegrees: Double,
                           pitchDegrees: Double,
                           rollDegrees: Double) -> simd_quatf {
        guard yawDegrees.isFinite, pitchDegrees.isFinite, rollDegrees.isFinite else {
            return simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        }
        let yaw = Float(yawDegrees * .pi / 180)
        let pitch = Float(pitchDegrees * .pi / 180)
        let roll = Float(rollDegrees * .pi / 180)

        let qYaw = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
        let qPitch = simd_quatf(angle: -pitch, axis: SIMD3<Float>(1, 0, 0))
        let qRoll = simd_quatf(angle: -roll, axis: SIMD3<Float>(0, 0, 1))
        // Yaw about the world vertical, then pitch, then roll about the
        // head's own forward axis.
        return qYaw * qPitch * qRoll
    }

    /// Where the head's forward (+Z, toward the viewer) ends up — used by
    /// tests to pin the mirror convention.
    static func forwardVector(yawDegrees: Double,
                              pitchDegrees: Double,
                              rollDegrees: Double) -> SIMD3<Float> {
        quaternion(yawDegrees: yawDegrees,
                   pitchDegrees: pitchDegrees,
                   rollDegrees: rollDegrees).act(SIMD3<Float>(0, 0, 1))
    }

    /// Where the head's up (+Y) ends up.
    static func upVector(yawDegrees: Double,
                         pitchDegrees: Double,
                         rollDegrees: Double) -> SIMD3<Float> {
        quaternion(yawDegrees: yawDegrees,
                   pitchDegrees: pitchDegrees,
                   rollDegrees: rollDegrees).act(SIMD3<Float>(0, 1, 0))
    }
}
