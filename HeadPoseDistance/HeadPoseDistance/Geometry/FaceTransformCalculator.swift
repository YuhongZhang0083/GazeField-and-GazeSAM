import Foundation
import simd

/// Derives camera-relative face pose and the distance measurements defined in
/// the protocol from the raw ARKit world-space transforms.
///
/// Distance definitions:
/// - `forwardDepthMeters`  = |z| of the camera-relative face translation:
///   depth along the camera's optical axis. In ARKit camera space the camera
///   looks along -Z, so a face in front of the camera has z < 0.
/// - `headReferenceDistanceMeters` = Euclidean norm of the translation:
///   straight-line distance from the camera optical center to the ARKit face
///   reference origin (a point roughly at the center of the head, near the
///   nose bridge — NOT the skin surface).
struct CameraRelativeFacePose {
    let cameraFromFace: simd_float4x4
    let translation: SIMD3<Float>
    let rotation: simd_quatf
    let forwardDepthMeters: Double
    let headReferenceDistanceMeters: Double
}

enum FaceTransformCalculator {

    /// Computes the camera-relative face pose, or nil when either transform is
    /// numerically invalid.
    static func computePose(worldFromCamera: simd_float4x4,
                            worldFromFace: simd_float4x4) -> CameraRelativeFacePose? {
        guard MathSupport.isFinite(worldFromCamera),
              MathSupport.isFinite(worldFromFace) else { return nil }

        let cameraFromFace = MathSupport.cameraFromFace(worldFromCamera: worldFromCamera,
                                                        worldFromFace: worldFromFace)
        guard MathSupport.isFinite(cameraFromFace) else { return nil }

        let t = MathSupport.translation(of: cameraFromFace)
        guard t.x.isFinite, t.y.isFinite, t.z.isFinite else { return nil }

        guard let q = MathSupport.quaternion(of: cameraFromFace) else { return nil }

        let forwardDepth = Double(abs(t.z))
        let headReference = Double(simd_length(t))

        return CameraRelativeFacePose(cameraFromFace: cameraFromFace,
                                      translation: t,
                                      rotation: q,
                                      forwardDepthMeters: forwardDepth,
                                      headReferenceDistanceMeters: headReference)
    }

    /// Estimated screen-to-face distance:
    ///
    ///     estimatedScreenToFace = trueDepthFaceSurface - cameraBehindScreenOffset
    ///
    /// TrueDepth measures distance to the front CAMERA, not the display glass.
    /// The offset is device-specific and defaults to 0 (uncalibrated).
    static func estimatedScreenToFaceMeters(trueDepthFaceSurfaceMeters: Double,
                                            cameraBehindScreenOffsetMeters: Double) -> Double {
        trueDepthFaceSurfaceMeters - cameraBehindScreenOffsetMeters
    }

    /// Column-major flattening of a 4x4 transform for export/debug.
    static func flatten(_ m: simd_float4x4) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(16)
        for c in [m.columns.0, m.columns.1, m.columns.2, m.columns.3] {
            out.append(contentsOf: [c.x, c.y, c.z, c.w])
        }
        return out
    }
}
