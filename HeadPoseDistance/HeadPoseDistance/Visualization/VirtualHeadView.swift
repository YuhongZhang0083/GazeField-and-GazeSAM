import SwiftUI
import SceneKit

/// Generic, privacy-preserving 3D head that mirrors the tracked head pose.
///
/// Procedurally built (ellipsoid skull + nose + ear hints) — no face
/// geometry from ARKit, no camera texture, nothing resembling the user's
/// identity, nothing persisted. Orientation comes from the neutral-relative
/// yaw/pitch/roll via `VirtualHeadOrientation`; position shifts subtly with
/// the measured lateral face offset and scale with distance so the head can
/// be aligned inside a fixed on-screen boundary.
///
/// When tracking is lost the head fades to a dim outline-like state.
struct VirtualHeadView: UIViewRepresentable {
    var yawDegrees: Double
    var pitchDegrees: Double
    var rollDegrees: Double
    /// Lateral offsets in the user's frame (meters); nil hides the offset.
    var userRightOffsetMeters: Double?
    var userUpOffsetMeters: Double?
    /// Distance deviation from baseline (meters); + = too far → smaller head.
    var distanceDeviationMeters: Double?
    var faceTracked: Bool

    /// Scene-units-per-meter for the lateral offset visualization.
    static let offsetScale: Float = 6.0
    /// Head shrink/grow per meter of distance deviation.
    static let distanceScalePerMeter: Float = 3.0

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = Self.makeScene()
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling2X
        view.isUserInteractionEnabled = false
        view.rendersContinuously = false
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        guard let head = view.scene?.rootNode.childNode(withName: "head",
                                                        recursively: false) else { return }
        SCNTransaction.begin()
        // Short implicit animation smooths 15 Hz snapshot updates without
        // adding perceptible lag.
        SCNTransaction.animationDuration = 0.08

        head.simdOrientation = VirtualHeadOrientation.quaternion(
            yawDegrees: yawDegrees,
            pitchDegrees: pitchDegrees,
            rollDegrees: rollDegrees)

        let dx = Float(userRightOffsetMeters ?? 0) * Self.offsetScale
        let dy = Float(userUpOffsetMeters ?? 0) * Self.offsetScale
        head.simdPosition = SIMD3<Float>(dx.clamped(to: -0.8...0.8),
                                         dy.clamped(to: -0.8...0.8),
                                         0)

        let deviation = Float(distanceDeviationMeters ?? 0)
        let scale = (1 - deviation * Self.distanceScalePerMeter).clamped(to: 0.6...1.5)
        head.simdScale = SIMD3<Float>(repeating: scale)

        // Tracking-lost state: fade toward a ghost outline.
        head.opacity = faceTracked ? 1.0 : 0.22

        SCNTransaction.commit()
    }

    // MARK: - Scene construction

    private static func makeScene() -> SCNScene {
        let scene = SCNScene()

        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = 1.0
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 4)
        scene.rootNode.addChildNode(cameraNode)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 400
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 700
        key.eulerAngles = SCNVector3(-0.5, 0.4, 0)
        scene.rootNode.addChildNode(key)

        scene.rootNode.addChildNode(makeHeadNode())
        return scene
    }

    /// Deliberately generic: an ellipsoid skull, a simple nose so the facing
    /// direction is obvious, and two ear hints for lateral orientation.
    static func makeHeadNode() -> SCNNode {
        let head = SCNNode()
        head.name = "head"

        let material = SCNMaterial()
        material.diffuse.contents = UIColor(white: 0.72, alpha: 1.0)
        material.roughness.contents = 0.7

        let skullGeometry = SCNSphere(radius: 0.5)
        skullGeometry.segmentCount = 32
        skullGeometry.materials = [material]
        let skull = SCNNode(geometry: skullGeometry)
        skull.simdScale = SIMD3<Float>(0.80, 1.05, 0.85)
        head.addChildNode(skull)

        // Nose: unmistakable forward (+Z) indicator.
        let noseGeometry = SCNCone(topRadius: 0.0, bottomRadius: 0.09, height: 0.28)
        noseGeometry.materials = [material]
        let nose = SCNNode(geometry: noseGeometry)
        nose.position = SCNVector3(0, -0.02, 0.46)
        nose.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
        nose.name = "nose"
        head.addChildNode(nose)

        // Ear hints.
        for side: Float in [-1, 1] {
            let earGeometry = SCNSphere(radius: 0.09)
            earGeometry.materials = [material]
            let ear = SCNNode(geometry: earGeometry)
            ear.position = SCNVector3(side * 0.42, 0, 0)
            head.addChildNode(ear)
        }

        return head
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

// The head-position boundary is composed in `MeasurementView`
// (`CenteredHeadBoundary`) so it can be centered on the fixation dot.
