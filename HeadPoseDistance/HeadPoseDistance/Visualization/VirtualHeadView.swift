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
    /// Orientation the spiral-sweep guide is asking for, or nil outside the
    /// sweep. Rendered as a translucent oversized outline co-located with the
    /// solid head: the participant "fills" the outline by rotating.
    ///
    /// Co-location is the whole point. A guide that moved *away* from the
    /// fixation dot would pull the eyes off it — and the entire method depends
    /// on the eyes staying on the dot while only the head moves. Here the
    /// guide conveys a 3D orientation from the same screen position as the
    /// dot, so following it requires no gaze shift.
    var targetYawDegrees: Double?
    var targetPitchDegrees: Double?
    /// True while the guide is waiting for the head to catch up — the outline
    /// warms to amber as a peripheral "you're behind" cue.
    var guideStalled: Bool = false

    /// Scene-units-per-meter for the lateral offset visualization.
    static let offsetScale: Float = 6.0
    /// Head shrink/grow per meter of distance deviation.
    static let distanceScalePerMeter: Float = 3.0
    /// The guide outline is drawn slightly larger than the head so an aligned
    /// head nests inside it rather than z-fighting with it.
    static let guideScale: Float = 1.14

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
        guard let root = view.scene?.rootNode,
              let head = root.childNode(withName: "head", recursively: false) else { return }
        updateGuide(root.childNode(withName: "guideHead", recursively: false))
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

    /// Points the guide outline at the requested orientation, or hides it when
    /// no sweep is running.
    private func updateGuide(_ guide: SCNNode?) {
        guard let guide else { return }
        guard let yaw = targetYawDegrees, let pitch = targetPitchDegrees else {
            guide.isHidden = true
            return
        }
        guide.isHidden = false
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.08
        // Roll is never guided — the sweep is a (yaw, pitch) path, and asking
        // for a head roll would add a rotation the gaze-field model does not
        // use.
        guide.simdOrientation = VirtualHeadOrientation.quaternion(
            yawDegrees: yaw, pitchDegrees: pitch, rollDegrees: 0)
        guide.simdScale = SIMD3<Float>(repeating: Self.guideScale)
        guide.opacity = guideStalled ? 0.55 : 0.32
        guide.enumerateHierarchy { node, _ in
            node.geometry?.firstMaterial?.diffuse.contents =
                guideStalled ? UIColor.systemOrange : UIColor.systemTeal
        }
        SCNTransaction.commit()
    }

    // MARK: - Scene construction

    private static func makeScene() -> SCNScene {
        let scene = SCNScene()

        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        // Half-height of the visible area in scene units. The head is ~1.05
        // units tall, so 0.68 makes it fill ~77% of the view instead of the
        // ~52% that scale 1.0 gave (which made the head look lost inside the
        // boundary oval).
        camera.orthographicScale = 0.68
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
        scene.rootNode.addChildNode(makeGuideNode())
        return scene
    }

    /// Translucent copy of the head used as the spiral-sweep guide. Same
    /// silhouette as the participant's head so "match the outline" is
    /// unambiguous, but unlit and see-through so it reads as a target rather
    /// than as a second head.
    static func makeGuideNode() -> SCNNode {
        let guide = makeHeadNode()
        guide.enumerateHierarchy { node, _ in
            guard let material = node.geometry?.firstMaterial else { return }
            material.diffuse.contents = UIColor.systemTeal
            material.lightingModel = .constant
            // Never occlude the solid head — the participant's own pose has to
            // stay readable through the guide.
            material.writesToDepthBuffer = false
        }
        // Named last: `enumerateHierarchy` visits the root too, so renaming
        // before it would have to be undone here anyway.
        guide.name = "guideHead"
        guide.isHidden = true
        guide.simdScale = SIMD3<Float>(repeating: guideScale)
        guide.opacity = 0.32
        return guide
    }

    /// Deliberately generic — an ellipsoid skull with a nose (unmistakable
    /// facing indicator) and two ear hints for lateral orientation. Resembles
    /// nobody; no eyes or mouth.
    static func makeHeadNode() -> SCNNode {
        let head = SCNNode()
        head.name = "head"

        let skin = SCNMaterial()
        skin.diffuse.contents = UIColor(white: 0.72, alpha: 1.0)
        skin.roughness.contents = 0.7

        let skullGeometry = SCNSphere(radius: 0.5)
        skullGeometry.segmentCount = 32
        skullGeometry.materials = [skin]
        let skull = SCNNode(geometry: skullGeometry)
        skull.simdScale = SIMD3<Float>(0.80, 1.05, 0.85)
        head.addChildNode(skull)

        // Nose: unmistakable forward (+Z) indicator.
        let noseGeometry = SCNCone(topRadius: 0.0, bottomRadius: 0.09, height: 0.28)
        noseGeometry.materials = [skin]
        let nose = SCNNode(geometry: noseGeometry)
        nose.position = SCNVector3(0, -0.02, 0.46)
        nose.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
        nose.name = "nose"
        head.addChildNode(nose)

        // Ear hints.
        for side: Float in [-1, 1] {
            let earGeometry = SCNSphere(radius: 0.09)
            earGeometry.materials = [skin]
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
