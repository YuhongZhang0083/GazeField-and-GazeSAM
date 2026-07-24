import Foundation
import simd

/// User-readable Euler angles in degrees.
struct EulerAngles: Codable, Equatable {
    var yawDegrees: Double
    var pitchDegrees: Double
    var rollDegrees: Double

    static let zero = EulerAngles(yawDegrees: 0, pitchDegrees: 0, rollDegrees: 0)
}

/// Converts rotations (kept internally as quaternions / rotation matrices)
/// into Euler angles for display and export.
///
/// ## Conventions (documented per protocol requirements)
///
/// - All frames are right-handed.
/// - Face (body) frame assumption for ARFaceAnchor: +Y up through the top of
///   the head, +Z outward through the nose; right-handedness then gives
///   +X out of the face's own right side.
/// - Decomposition order: R = Ry(yaw) · Rx(pitch) · Rz(roll)
///   (intrinsic yaw → pitch → roll about the face's own axes).
/// - Angles are extracted in radians and converted to degrees, then wrapped
///   to [-180, 180).
/// - Rotations are NEVER composed or averaged as Euler angles; composition
///   and smoothing happen on quaternions. Euler angles are presentation only.
///
/// ## Raw sign meaning under this decomposition (before convention mapping)
///
/// - +yaw   = rotation about face +Y: nose (+Z) swings toward face +X
///            (toward the user's own right, under the axis assumption above).
/// - +pitch = rotation about face +X: nose (+Z) tips toward -Y (nose DOWN).
/// - +roll  = rotation about face +Z: face +X (right side) lifts toward +Y
///            (tilt toward the LEFT shoulder).
///
/// `HeadPoseConvention` maps these raw signs onto the user-facing convention
/// (+yaw right, +pitch up, +roll toward right shoulder). The mapping lives in
/// that single isolated layer and MUST be verified on a physical device
/// (see README checklist).
enum HeadPoseEstimator {

    /// Extracts Euler angles (degrees) from a unit quaternion using the
    /// R = Ry(yaw)·Rx(pitch)·Rz(roll) decomposition.
    ///
    /// With m[row][col] of the rotation matrix:
    ///   pitch = asin(-m12)
    ///   yaw   = atan2(m02, m22)   (when cos(pitch) != 0)
    ///   roll  = atan2(m10, m11)
    /// Near gimbal lock (|pitch| -> 90°) roll is set to 0 and yaw absorbs the
    /// remaining rotation.
    static func eulerAngles(from q: simd_quatf) -> EulerAngles {
        let m = simd_float3x3(simd_normalize(q))
        // simd matrices are column-major: m.columns.c[r] is element (row r, col c).
        let m02 = Double(m.columns.2.x)
        let m12 = Double(m.columns.2.y)
        let m22 = Double(m.columns.2.z)
        let m10 = Double(m.columns.0.y)
        let m11 = Double(m.columns.1.y)
        let m00 = Double(m.columns.0.x)
        let m01 = Double(m.columns.1.x)

        let sp = max(-1.0, min(1.0, -m12))
        let pitch = asin(sp)

        let yaw: Double
        let roll: Double
        if abs(sp) < 0.9999 {
            yaw = atan2(m02, m22)
            roll = atan2(m10, m11)
        } else {
            // Gimbal lock: only (yaw - roll) at pitch=+90, (yaw + roll) at
            // pitch=-90, is observable. Report it as yaw with roll = 0.
            yaw = sp > 0 ? atan2(m01, m00) : atan2(-m01, m00)
            roll = 0
        }

        return EulerAngles(yawDegrees: MathSupport.wrapDegrees(MathSupport.degrees(yaw)),
                           pitchDegrees: MathSupport.wrapDegrees(MathSupport.degrees(pitch)),
                           rollDegrees: MathSupport.wrapDegrees(MathSupport.degrees(roll)))
    }
}

/// Isolated presentation layer that converts raw SDK-derived angle signs into
/// the user-facing convention:
///
/// - positive yaw:   head turns toward the user's RIGHT
/// - positive pitch: head rotates UP
/// - positive roll:  head tilts toward the user's RIGHT shoulder
///
/// Default multipliers follow the geometric derivation in
/// `HeadPoseEstimator`'s documentation. They are configurable because the
/// actual ARKit face-anchor axis directions must be confirmed on a physical
/// device; if a sign is observed inverted, flip it HERE and nowhere else.
struct HeadPoseConvention: Codable, Equatable {
    var yawSign: Double = 1.0
    var pitchSign: Double = -1.0   // raw +pitch is nose-down; user-facing + is up
    var rollSign: Double = -1.0    // raw +roll is toward left shoulder; user-facing + is right

    static let `default` = HeadPoseConvention()

    func userFacing(from raw: EulerAngles) -> EulerAngles {
        EulerAngles(yawDegrees: MathSupport.wrapDegrees(raw.yawDegrees * yawSign),
                    pitchDegrees: MathSupport.wrapDegrees(raw.pitchDegrees * pitchSign),
                    rollDegrees: MathSupport.wrapDegrees(raw.rollDegrees * rollSign))
    }
}
