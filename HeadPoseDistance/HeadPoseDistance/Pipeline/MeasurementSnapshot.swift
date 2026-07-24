import Foundation
import CoreGraphics
import UIKit
import simd

/// Immutable display state published from the measurement pipeline to the UI
/// (~15 Hz). Contains everything the live view, results banner, and debug
/// screen show. Never used for recording — recording uses MeasurementSample.
struct MeasurementSnapshot {

    // MARK: Session / stage
    var stage: MeasurementStage = .preview
    var faceTracked = false
    var trackingStateDescription = "Starting camera…"
    var interrupted = false
    var sessionErrorMessage: String?
    var frameRateHz: Double = 0

    // MARK: Protocol
    var currentPhase: ProtocolPhase = .idle
    var phaseInstruction: String = ProtocolPhase.idle.instruction
    var phaseSymbolName: String?
    var phaseProgress: Double = 0
    var recordingElapsedSeconds: Double = 0
    var recordingTotalSeconds: Double = 0
    var neutralCaptureProgress: Double = 0
    var acceptedSampleCount = 0
    var rejectedSampleCount = 0

    // MARK: Phone motion
    var phoneStability: PhoneStability = .unknown
    var phoneRotationRate: SIMD3<Double>?
    var phoneUserAcceleration: SIMD3<Double>?
    var phoneGravity: SIMD3<Double>?
    var phoneAttitudeChangeDegrees: Double?

    // MARK: Distances (meters)
    var forwardDepthMeters: Double?
    var headReferenceDistanceMeters: Double?
    var trueDepthSurfaceRawMeters: Double?
    var trueDepthSurfaceMedianFilteredMeters: Double?
    var trueDepthSurfaceEMAFilteredMeters: Double?
    var estimatedScreenToFaceMeters: Double?
    var screenOffsetCalibrated = false
    var baselineDistanceMeters: Double?
    var distanceDeviationMeters: Double?
    var distanceWarning = false
    var trueDepthAvailableThisFrame = false
    var trueDepthEverAvailable = false

    // MARK: Depth quality / debug
    var depthValidPixelCount = 0
    var depthTotalPixelCount = 0
    var depthValidPixelRatio: Double = 0
    var depthMapWidth = 0
    var depthMapHeight = 0
    var depthFormatDescription = "—"
    var depthROIDescription = "—"
    var depthConsistent: Bool?

    // MARK: Head-direction guidance
    /// Live evaluation of the head against the current phase's target.
    var directionProgress: HeadDirectionProgress = .none
    /// Directional phases whose target angle has actually been reached during
    /// this recording (drives the on-screen checklist).
    var completedDirections: Set<ProtocolPhase> = []
    /// Pose-driven guidance state, present while recording/paused.
    var guidance: GuidanceUIState?

    // MARK: Head-position boundary
    /// Alignment of the face against the distance band and lateral tolerance,
    /// derived from tracking data only (never the camera image).
    var alignment: FaceAlignmentState = .unknown

    // MARK: Orientation
    var hasNeutralPose = false
    var rawEuler: EulerAngles?
    var relativeEuler: EulerAngles?          // user-facing convention
    var relativeEulerRaw: EulerAngles?       // before sign convention
    var headAngularVelocityDegPerSec: Double?

    // MARK: Debug transforms / quaternions
    var worldFromCamera: simd_float4x4?
    var worldFromFace: simd_float4x4?
    var cameraFromFace: simd_float4x4?
    var translation: SIMD3<Float>?
    var rawQuaternion: simd_quatf?
    var neutralQuaternion: simd_quatf?
    var relativeQuaternion: simd_quatf?

    // MARK: Validation
    var sampleValid = false
    var confidence: Double = 0
    var rejectionReasons: [String] = []

    // MARK: Offset calibration
    var offsetCalibrationActive = false
    var offsetCalibrationProgress: Double = 0
    var cameraBehindScreenOffsetMeters: Double = 0

    // MARK: Debug preview (never saved)
    var debugPreviewImage: UIImage?
    var debugROIRectNormalized: CGRect?

    static let initial = MeasurementSnapshot()
}

/// Value-type mirror of the guidance controller's output for the UI layer.
struct GuidanceUIState: Equatable {
    var state: GuidedMovementController.StateKind
    var direction: ProtocolPhase?
    var instruction: String
    var feedbackMessage: String?
    var holdProgress: Double
    var approachProgress: Double
    var stageIndex: Int
    var stageCount: Int
    var isPaused: Bool
    var isComplete: Bool

    init(output: GuidedMovementController.GuidanceOutput) {
        state = output.state
        direction = output.direction
        instruction = output.instruction
        feedbackMessage = output.feedback?.message
        holdProgress = output.holdProgress
        approachProgress = output.approachProgress
        stageIndex = output.stageIndex
        stageCount = output.stageCount
        isPaused = output.isPaused
        isComplete = output.isComplete
    }
}
