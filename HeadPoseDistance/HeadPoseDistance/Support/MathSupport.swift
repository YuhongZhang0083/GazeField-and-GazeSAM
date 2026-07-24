import Foundation
import simd

/// Pure math helpers used throughout the pipeline. Everything here is
/// deterministic and covered by unit tests.
///
/// Coordinate-system notes (documented assumptions, verified by unit tests
/// where possible and flagged for physical-device verification in README):
///
/// - ARKit world and camera spaces are right-handed. Camera space:
///   +X right, +Y up, +Z toward the viewer (the camera looks along -Z).
/// - `ARFrame.camera.transform` is worldFromCamera (camera pose in world).
/// - `ARFaceAnchor.transform` is worldFromFace (face pose in world).
/// - Face-anchor space (Apple): right-handed, +Y up through the top of the
///   head, +Z outward through the nose toward the camera when facing it.
///   Right-handedness then forces +X out of the face's own right side.
enum MathSupport {

    // MARK: - Transform composition

    /// The face pose expressed in the camera's coordinate system.
    ///
    ///     cameraFromFace = inverse(worldFromCamera) * worldFromFace
    ///
    /// A point p_face in face coordinates maps to camera coordinates via
    /// p_camera = cameraFromFace * p_face.
    static func cameraFromFace(worldFromCamera: simd_float4x4,
                               worldFromFace: simd_float4x4) -> simd_float4x4 {
        simd_mul(worldFromCamera.inverse, worldFromFace)
    }

    // MARK: - Component extraction

    static func translation(of m: simd_float4x4) -> SIMD3<Float> {
        SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }

    static func rotationMatrix(of m: simd_float4x4) -> simd_float3x3 {
        simd_float3x3(
            SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z),
            SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z),
            SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        )
    }

    /// Extracts a normalized quaternion from the rotation part of a rigid
    /// transform. Columns are re-normalized first to suppress accumulated
    /// floating-point drift. Returns nil for degenerate (non-rotation) input.
    static func quaternion(of m: simd_float4x4) -> simd_quatf? {
        var r = rotationMatrix(of: m)
        let l0 = simd_length(r.columns.0)
        let l1 = simd_length(r.columns.1)
        let l2 = simd_length(r.columns.2)
        guard l0 > 1e-6, l1 > 1e-6, l2 > 1e-6,
              l0.isFinite, l1.isFinite, l2.isFinite else { return nil }
        r.columns.0 /= l0
        r.columns.1 /= l1
        r.columns.2 /= l2
        guard simd_determinant(r) > 0.5 else { return nil }
        let q = simd_normalize(simd_quatf(r))
        guard q.vector.x.isFinite, q.vector.y.isFinite,
              q.vector.z.isFinite, q.vector.w.isFinite else { return nil }
        return q
    }

    // MARK: - Constructors (used by tests and synthetic data)

    static func makeTranslation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(t.x, t.y, t.z, 1)
        return m
    }

    static func makeRotationX(radians: Float) -> simd_float4x4 {
        simd_float4x4(simd_quatf(angle: radians, axis: SIMD3<Float>(1, 0, 0)))
    }

    static func makeRotationY(radians: Float) -> simd_float4x4 {
        simd_float4x4(simd_quatf(angle: radians, axis: SIMD3<Float>(0, 1, 0)))
    }

    static func makeRotationZ(radians: Float) -> simd_float4x4 {
        simd_float4x4(simd_quatf(angle: radians, axis: SIMD3<Float>(0, 0, 1)))
    }

    // MARK: - Validity

    static func isFinite(_ m: simd_float4x4) -> Bool {
        for c in [m.columns.0, m.columns.1, m.columns.2, m.columns.3] {
            if !(c.x.isFinite && c.y.isFinite && c.z.isFinite && c.w.isFinite) {
                return false
            }
        }
        return true
    }

    // MARK: - Angles

    /// Wraps an angle in degrees into [-180, 180).
    static func wrapDegrees(_ degrees: Double) -> Double {
        let r = fmod(degrees + 180.0, 360.0)
        return r < 0 ? r + 180.0 : r - 180.0
    }

    static func degrees(_ radians: Double) -> Double { radians * 180.0 / .pi }
    static func radians(_ degrees: Double) -> Double { degrees * .pi / 180.0 }

    // MARK: - Quaternions

    /// Shortest rotation angle between two unit quaternions, in radians.
    /// Sign-insensitive (q and -q represent the same rotation).
    static func angleBetween(_ a: simd_quatf, _ b: simd_quatf) -> Double {
        let qa = simd_normalize(a)
        let qb = simd_normalize(b)
        let d = min(1.0, Double(abs(simd_dot(qa.vector, qb.vector))))
        return 2.0 * acos(d)
    }

    /// Robust mean of a cluster of nearby unit quaternions.
    ///
    /// Each quaternion's sign is first aligned with the first element
    /// (q and -q are the same rotation), then components are averaged and the
    /// result normalized. This is a standard, well-behaved approximation for
    /// tightly clustered orientations such as a neutral-pose capture window.
    /// It is NOT valid for widely spread rotations.
    static func averageQuaternion(_ quaternions: [simd_quatf]) -> simd_quatf? {
        guard let first = quaternions.first else { return nil }
        var sum = SIMD4<Float>.zero
        for q in quaternions {
            var v = simd_normalize(q).vector
            if simd_dot(v, first.vector) < 0 { v = -v }
            sum += v
        }
        let length = simd_length(sum)
        guard length > 1e-6, length.isFinite else { return nil }
        return simd_quatf(vector: sum / length)
    }

    /// Rotation of `current` relative to `neutral`, expressed in the face's
    /// own (body) frame:
    ///
    ///     relativeRotation = inverse(neutralRotation) * currentRotation
    ///
    /// Because both rotations are cameraFromFace orientations, the fixed
    /// camera frame cancels and the result is orientation-change in face
    /// coordinates — independent of how the camera sensor is oriented
    /// relative to the portrait UI.
    static func relativeRotation(neutral: simd_quatf, current: simd_quatf) -> simd_quatf {
        simd_normalize(neutral.inverse * current)
    }
}
