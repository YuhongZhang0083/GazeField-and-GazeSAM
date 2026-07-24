import Foundation
import ARKit

/// Owns the ARSession for TrueDepth face tracking. All delegate callbacks are
/// delivered on the supplied serial queue (never the main thread); the
/// pipeline processes frames there and publishes UI state separately.
///
/// This class deliberately contains no measurement logic — it forwards raw
/// ARFrames and session lifecycle events.
final class ARFaceTrackingManager: NSObject, ARSessionDelegate {

    enum SessionEvent {
        case interrupted
        case interruptionEnded
        case failed(String)
        case trackingStateChanged(String)
    }

    let session = ARSession()
    private let callbackQueue: DispatchQueue

    /// Called on `callbackQueue` for every ARFrame. The frame must be used
    /// synchronously inside the callback and not retained (ARKit reuses the
    /// underlying buffers).
    var onFrame: ((ARFrame) -> Void)?

    /// Called on `callbackQueue` for session lifecycle events.
    var onEvent: ((SessionEvent) -> Void)?

    static var isFaceTrackingSupported: Bool {
        ARFaceTrackingConfiguration.isSupported
    }

    init(callbackQueue: DispatchQueue) {
        self.callbackQueue = callbackQueue
        super.init()
        session.delegate = self
        session.delegateQueue = callbackQueue
    }

    func start() {
        guard Self.isFaceTrackingSupported else { return }
        let configuration = ARFaceTrackingConfiguration()
        configuration.maximumNumberOfTrackedFaces = 1
        configuration.isWorldTrackingEnabled = false
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        session.pause()
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        onFrame?(frame)
    }

    // MARK: - ARSessionObserver

    func session(_ session: ARSession, didFailWithError error: Error) {
        onEvent?(.failed(error.localizedDescription))
    }

    func sessionWasInterrupted(_ session: ARSession) {
        onEvent?(.interrupted)
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        onEvent?(.interruptionEnded)
        // Re-run to recover tracking after the interruption.
        start()
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        onEvent?(.trackingStateChanged(Self.describe(camera.trackingState)))
    }

    static func describe(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal:
            return "Tracking Normal"
        case .notAvailable:
            return "Tracking Unavailable"
        case .limited(let reason):
            switch reason {
            case .initializing: return "Tracking Limited (initializing)"
            case .excessiveMotion: return "Tracking Limited (excessive motion)"
            case .insufficientFeatures: return "Tracking Limited (insufficient features)"
            case .relocalizing: return "Tracking Limited (relocalizing)"
            @unknown default: return "Tracking Limited"
            }
        }
    }
}
