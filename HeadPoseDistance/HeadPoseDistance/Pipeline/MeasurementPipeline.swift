import Foundation
import ARKit
import CoreImage
import UIKit
import simd

/// Per-frame measurement engine.
///
/// Threading model: every method except `init` MUST be called on `queue`
/// (the AR session delegate queue). The view model dispatches control calls
/// onto that queue and receives results via the `on…` closures, which are
/// always invoked on the main queue with value-type payloads.
final class MeasurementPipeline {

    let queue: DispatchQueue
    private(set) var config: MeasurementConfig
    private let motionMonitor: DeviceMotionMonitor
    private let stabilityFilter = PhoneStabilityFilter()
    private let convention = HeadPoseConvention.default

    // MARK: Outputs (invoked on the main queue)
    var onSnapshot: ((MeasurementSnapshot) -> Void)?
    var onNeutralResult: ((Result<NeutralPose, NeutralCaptureError>) -> Void)?
    var onRecordingFinished: ((RecordedSession) -> Void)?
    var onPhaseChange: ((ProtocolPhase) -> Void)?
    var onOffsetCalibrationFinished: ((Result<Double, OffsetCalibrationError>) -> Void)?

    // MARK: Stage state
    private(set) var stage: MeasurementStage = .preview
    private var neutralPose: NeutralPose?
    private var neutralCollector: NeutralPoseCalibrator?
    private var recorder: SessionRecorder?
    /// The active recording protocol — eight-spoke or spiral sweep. Both
    /// conform to `ProtocolControlling`, so everything downstream of here is
    /// mode-agnostic.
    private var guidance: ProtocolControlling?
    private var recordingMode: RecordingMode = .freeExploration
    private var lastGuidanceOutput: ProtocolGuidanceOutput?
    private var recordingStartFrameTime: TimeInterval?
    private var pausedAccumulated: TimeInterval = 0
    private var pauseBeganAt: TimeInterval?
    private var lastPhase: ProtocolPhase = .idle
    private var interrupted = false
    private var sessionErrorMessage: String?
    private var trackingStateDescription = "Starting camera…"

    // MARK: Frame-to-frame state
    private var previousQuaternion: simd_quatf?
    private var previousFrameTimestamp: TimeInterval?
    private var lastFrameTimestamp: TimeInterval = 0
    private var frameRateEMA: Double = 0
    private var trueDepthEverAvailable = false
    private var surfaceFilter: DistanceFilterPipeline
    private var lastSnapshotPublish: TimeInterval = 0

    // MARK: Screen / metadata info (set by the view model)
    private var screenWidthPoints: Double = 0
    private var screenHeightPoints: Double = 0
    private var screenScale: Double = 0
    private var dotCenter = CGPoint.zero

    // MARK: Screen-offset state
    private var cameraBehindScreenOffsetMeters: Double
    private var screenOffsetCalibrated: Bool
    private var offsetCalibrationSamples: [Double]?
    private var offsetCalibrationReferenceMeters: Double = 0
    private var offsetCalibrationStartTime: TimeInterval?

    // MARK: Debug preview
    private var debugPreviewEnabled = false
    private var lastPreviewTime: TimeInterval = 0
    private lazy var ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Live camera preview sink. Receives the captured image for on-screen
    /// display only — never recorded, never exported.
    weak var previewRenderer: CameraPreviewRenderer?

    /// Set of directional phases whose target angle has actually been reached
    /// during this recording, used to drive the on-screen progress checklist.
    private(set) var completedDirections: Set<ProtocolPhase> = []

    init(queue: DispatchQueue, config: MeasurementConfig, motionMonitor: DeviceMotionMonitor) {
        self.queue = queue
        self.config = config
        self.motionMonitor = motionMonitor
        self.surfaceFilter = DistanceFilterPipeline(config: config)
        let stored = ScreenDistanceCalibrator.loadOffset()
        self.cameraBehindScreenOffsetMeters = stored.offsetMeters
        self.screenOffsetCalibrated = stored.calibrated
    }

    // MARK: - Control (call on `queue`)

    func updateScreenInfo(widthPoints: Double, heightPoints: Double,
                          scale: Double, dotCenter: CGPoint) {
        screenWidthPoints = widthPoints
        screenHeightPoints = heightPoints
        screenScale = scale
        self.dotCenter = dotCenter
    }

    func setDebugPreviewEnabled(_ enabled: Bool) {
        debugPreviewEnabled = enabled
    }

    func noteInterruption(_ active: Bool) {
        interrupted = active
        if active, stage == .recording {
            pauseRecording()
        }
    }

    func noteSessionError(_ message: String) {
        sessionErrorMessage = message
    }

    func noteTrackingState(_ description: String) {
        trackingStateDescription = description
    }

    func beginNeutralCapture() {
        guard stage == .preview || stage == .neutralReady else { return }
        neutralCollector = NeutralPoseCalibrator(startedAtFrameTime: lastFrameTimestamp)
        stage = .capturingNeutral
    }

    func startRecording(mode: RecordingMode) {
        guard stage == .neutralReady, neutralPose != nil else { return }
        recorder = SessionRecorder()
        recordingMode = mode
        switch mode {
        case .eightSpoke:
            guidance = GuidedMovementController(config: config)
        case .freeExploration:
            guidance = FreeExplorationController(config: config)
        }
        lastGuidanceOutput = nil
        recordingStartFrameTime = nil   // set on the first recorded frame
        pausedAccumulated = 0
        pauseBeganAt = nil
        lastPhase = .idle
        completedDirections = []
        motionMonitor.setReferenceAttitude()
        stage = .recording
    }

    func pauseRecording() {
        guard stage == .recording else { return }
        pauseBeganAt = lastFrameTimestamp
        stage = .paused
    }

    func resumeRecording() {
        guard stage == .paused else { return }
        if let began = pauseBeganAt {
            pausedAccumulated += max(0, lastFrameTimestamp - began)
        }
        pauseBeganAt = nil
        stage = .recording
    }

    func stopRecording() {
        guard stage == .recording || stage == .paused else { return }
        finishRecording()
    }

    /// Discards the current recording and returns to the ready state
    /// (the neutral pose is kept; use `resetNeutral` to recapture it).
    func restartSession() {
        recorder = nil
        guidance = nil
        lastGuidanceOutput = nil
        recordingStartFrameTime = nil
        pausedAccumulated = 0
        pauseBeganAt = nil
        surfaceFilter.reset()
        stage = neutralPose != nil ? .neutralReady : .preview
    }

    func resetNeutral() {
        neutralPose = nil
        neutralCollector = nil
        surfaceFilter.reset()
        stage = .preview
    }

    func beginOffsetCalibration(referenceScreenDistanceMeters: Double) {
        offsetCalibrationSamples = []
        offsetCalibrationReferenceMeters = referenceScreenDistanceMeters
        offsetCalibrationStartTime = lastFrameTimestamp
    }

    func cancelOffsetCalibration() {
        offsetCalibrationSamples = nil
    }

    func resetScreenOffset() {
        cameraBehindScreenOffsetMeters = 0
        screenOffsetCalibrated = false
    }

    func applyScreenOffset(_ offsetMeters: Double, calibrated: Bool) {
        cameraBehindScreenOffsetMeters = offsetMeters
        screenOffsetCalibrated = calibrated
    }

    // MARK: - Frame processing (called on `queue` from the AR delegate)

    func process(frame: ARFrame) {
        let frameTime = frame.timestamp
        let timestampMonotonic = previousFrameTimestamp.map { frameTime > $0 } ?? true

        // Live preview: hand the captured image straight to the GPU renderer.
        // Done first and unconditionally so preview latency never depends on
        // the measurement work below.
        previewRenderer?.submit(pixelBuffer: frame.capturedImage)

        // Frame-rate estimate.
        if let prev = previousFrameTimestamp, frameTime > prev {
            let instantaneous = 1.0 / (frameTime - prev)
            frameRateEMA = frameRateEMA == 0 ? instantaneous
                : 0.1 * instantaneous + 0.9 * frameRateEMA
        }
        lastFrameTimestamp = frameTime

        // Face anchor and camera-relative pose.
        let faceAnchor = frame.anchors.compactMap { $0 as? ARFaceAnchor }.first
        let faceTracked = faceAnchor?.isTracked ?? false
        let worldFromCamera = frame.camera.transform

        var pose: CameraRelativeFacePose?
        var worldFromFace: simd_float4x4?
        if let anchor = faceAnchor {
            worldFromFace = anchor.transform
            pose = FaceTransformCalculator.computePose(worldFromCamera: worldFromCamera,
                                                       worldFromFace: anchor.transform)
        }

        // Orientation and angular velocity.
        var rawEuler: EulerAngles?
        var relativeQuat: simd_quatf?
        var relativeEulerRaw: EulerAngles?
        var relativeEulerUser: EulerAngles?
        var angularVelocity: Double?

        if let pose {
            rawEuler = HeadPoseEstimator.eulerAngles(from: pose.rotation)
            if let prevQ = previousQuaternion, let prevT = previousFrameTimestamp,
               frameTime > prevT {
                let dAngle = MathSupport.angleBetween(prevQ, pose.rotation)
                angularVelocity = MathSupport.degrees(dAngle) / (frameTime - prevT)
            }
            if let neutral = neutralPose {
                let rel = MathSupport.relativeRotation(neutral: neutral.simdQuaternion,
                                                       current: pose.rotation)
                relativeQuat = rel
                let relRaw = HeadPoseEstimator.eulerAngles(from: rel)
                relativeEulerRaw = relRaw
                relativeEulerUser = convention.userFacing(from: relRaw)
            }
            previousQuaternion = pose.rotation
        } else {
            previousQuaternion = nil
        }
        previousFrameTimestamp = frameTime

        // TrueDepth face-surface distance.
        var depthStats: DepthROIStatistics?
        let depthDataPresent = frame.capturedDepthData != nil
        if depthDataPresent { trueDepthEverAvailable = true }
        if let depthData = frame.capturedDepthData, let pose, faceTracked,
           let worldFromFace {
            let facePosition = MathSupport.translation(of: worldFromFace)
            // Captured image is in sensor-native landscape orientation;
            // .landscapeRight with viewport = imageResolution yields
            // captured-image pixel coordinates (assumption verified via the
            // consistency check below and the README device checklist).
            let projected = frame.camera.projectPoint(facePosition,
                                                      orientation: .landscapeRight,
                                                      viewportSize: frame.camera.imageResolution)
            depthStats = TrueDepthDistanceEstimator.sampleFaceRegion(
                depthData: depthData,
                projectedImagePoint: projected,
                imageResolution: frame.camera.imageResolution,
                headReferenceForwardDepth: pose.forwardDepthMeters,
                config: config)
        }

        // Accept the surface value only when present, sufficiently supported,
        // and consistent with the head-reference depth.
        var surfaceRaw: Double?
        if let stats = depthStats, let median = stats.medianMeters,
           stats.validPixelCount >= config.minValidDepthPixelCount,
           stats.validRatio >= config.minValidDepthPixelRatio,
           stats.consistentWithHeadReference != false {
            surfaceRaw = median
            surfaceFilter.add(raw: median)
        }
        let surfaceMedian = surfaceRaw != nil ? surfaceFilter.lastMedian : nil
        let surfaceEMA = surfaceRaw != nil ? surfaceFilter.lastEMA : nil

        var estimatedScreen: Double?
        if let s = surfaceRaw {
            estimatedScreen = FaceTransformCalculator.estimatedScreenToFaceMeters(
                trueDepthFaceSurfaceMeters: s,
                cameraBehindScreenOffsetMeters: cameraBehindScreenOffsetMeters)
        }

        // Distance deviation from the neutral baseline. Uses the ARKit
        // head-reference distance (head-centre origin), which stays essentially
        // constant while the head rotates and moves only when the participant
        // physically moves closer/farther — the correct signal for holding the
        // neutral distance. The TrueDepth surface distance swings with head
        // rotation, so it is recorded/displayed but NOT used for this check.
        var deviation: Double?
        var baseline: Double?
        if let neutral = neutralPose, let pose {
            baseline = neutral.baselineHeadReferenceDistanceMeters
            deviation = pose.headReferenceDistanceMeters - baseline!
        }

        // Head-position alignment (distance band + fixed lateral bounds around
        // the neutral face position). Computed here so the same verdict drives
        // validation, guided-pause, and the on-screen boundary.
        let neutralTranslation = neutralPose.map {
            SIMD3<Float>($0.translation[0], $0.translation[1], $0.translation[2])
        }
        let alignment = FaceAlignmentEvaluator.evaluate(
            primaryDistanceMeters: surfaceEMA ?? pose?.headReferenceDistanceMeters,
            deviationMeters: deviation,
            translation: pose?.translation,
            neutralTranslation: neutralTranslation,
            faceTracked: faceTracked,
            config: config)
        // Lateral bounds are only meaningful once a neutral position exists.
        let lateralInBounds = neutralPose == nil ? true : alignment.withinLateralTolerance

        // Phone motion — smoothed + debounced so isolated Core Motion spikes
        // don't flash "excessive" and needlessly pause the protocol.
        let motion = motionMonitor.latest()
        let stability: PhoneStability
        if let m = motion {
            stability = stabilityFilter.update(
                rotationRateMagnitude: m.rotationRateMagnitude,
                accelerationMagnitude: m.userAccelerationMagnitude,
                attitudeChangeDegrees: m.attitudeChangeFromReferenceDegrees,
                timestamp: frameTime,
                config: config)
        } else {
            stability = .unknown
        }

        // Validation.
        let validationInput = ValidationInput(
            faceTracked: faceTracked,
            transformFinite: pose != nil,
            orientationFinite: pose != nil,
            headReferenceDistanceMeters: pose?.headReferenceDistanceMeters,
            distanceDeviationMeters: deviation,
            baselineDistanceMeters: baseline,
            faceLaterallyInBounds: lateralInBounds,
            depthExpected: trueDepthEverAvailable,
            depthAvailable: surfaceRaw != nil,
            depthValidPixelCount: depthStats?.validPixelCount,
            depthValidPixelRatio: depthStats?.validRatio,
            depthConsistent: depthStats?.consistentWithHeadReference,
            phoneStability: stability,
            headAngularVelocityDegPerSec: angularVelocity,
            timestampMonotonic: timestampMonotonic,
            interrupted: interrupted)
        let validation = SampleValidator.validate(validationInput, config: config)

        let warnThreshold: Double = {
            guard let b = baseline else { return config.distanceDeviationWarningMeters }
            return min(config.distanceDeviationWarningMeters,
                       b * config.distanceDeviationWarningFraction)
        }()
        let distanceStable = deviation.map { abs($0) <= warnThreshold } ?? true

        // Stage-specific work.
        switch stage {
        case .capturingNeutral:
            processNeutralCapture(frameTime: frameTime, pose: pose, faceTracked: faceTracked,
                                  surfaceRaw: surfaceRaw, angularVelocity: angularVelocity,
                                  stability: stability)
        case .recording:
            processRecording(frame: frame, frameTime: frameTime, pose: pose,
                             worldFromCamera: worldFromCamera, worldFromFace: worldFromFace,
                             faceTracked: faceTracked, rawEuler: rawEuler,
                             relativeEulerUser: relativeEulerUser,
                             angularVelocity: angularVelocity,
                             surfaceRaw: surfaceRaw, surfaceMedian: surfaceMedian,
                             surfaceEMA: surfaceEMA, estimatedScreen: estimatedScreen,
                             deviation: deviation, lateralInBounds: lateralInBounds,
                             depthStats: depthStats,
                             motion: motion, stability: stability,
                             validation: validation, distanceStable: distanceStable)
        default:
            break
        }

        // Offset calibration collection (runs in any stage).
        processOffsetCalibration(frameTime: frameTime, surfaceRaw: surfaceRaw,
                                 stability: stability)

        // Publish a throttled UI snapshot (~15 Hz).
        if frameTime - lastSnapshotPublish >= 1.0 / 15.0 {
            lastSnapshotPublish = frameTime
            publishSnapshot(frame: frame, frameTime: frameTime, pose: pose,
                            worldFromCamera: worldFromCamera, worldFromFace: worldFromFace,
                            faceTracked: faceTracked, rawEuler: rawEuler,
                            relativeQuat: relativeQuat, relativeEulerRaw: relativeEulerRaw,
                            relativeEulerUser: relativeEulerUser,
                            angularVelocity: angularVelocity,
                            depthDataPresent: depthDataPresent, depthStats: depthStats,
                            surfaceRaw: surfaceRaw, surfaceMedian: surfaceMedian,
                            surfaceEMA: surfaceEMA, estimatedScreen: estimatedScreen,
                            baseline: baseline, deviation: deviation,
                            distanceStable: distanceStable, motion: motion,
                            stability: stability, validation: validation,
                            alignment: alignment)
        }
    }

    // MARK: - Neutral capture

    private func processNeutralCapture(frameTime: TimeInterval,
                                       pose: CameraRelativeFacePose?,
                                       faceTracked: Bool,
                                       surfaceRaw: Double?,
                                       angularVelocity: Double?,
                                       stability: PhoneStability) {
        guard let collector = neutralCollector else { return }

        if faceTracked, let pose {
            collector.add(NeutralPoseCalibrator.Candidate(
                quaternion: pose.rotation,
                translation: pose.translation,
                headReferenceDistanceMeters: pose.headReferenceDistanceMeters,
                surfaceDistanceMeters: surfaceRaw,
                angularVelocityDegPerSec: angularVelocity,
                phoneStable: stability != .excessive,
                timestamp: frameTime))
        }

        let elapsed = frameTime - collector.startedAtFrameTime
        guard elapsed >= config.neutralCaptureDurationSeconds else { return }

        let result = collector.finalize(config: config)
        neutralCollector = nil
        switch result {
        case .success(let posture):
            neutralPose = posture
            stage = .neutralReady
        case .failure:
            stage = .preview
        }
        let cb = onNeutralResult
        DispatchQueue.main.async { cb?(result) }
    }

    // MARK: - Recording

    private func processRecording(frame: ARFrame, frameTime: TimeInterval,
                                  pose: CameraRelativeFacePose?,
                                  worldFromCamera: simd_float4x4,
                                  worldFromFace: simd_float4x4?,
                                  faceTracked: Bool,
                                  rawEuler: EulerAngles?,
                                  relativeEulerUser: EulerAngles?,
                                  angularVelocity: Double?,
                                  surfaceRaw: Double?, surfaceMedian: Double?,
                                  surfaceEMA: Double?, estimatedScreen: Double?,
                                  deviation: Double?, lateralInBounds: Bool,
                                  depthStats: DepthROIStatistics?,
                                  motion: DeviceMotionMonitor.Snapshot?,
                                  stability: PhoneStability,
                                  validation: ValidationResult,
                                  distanceStable: Bool) {
        guard let recorder, let guidance else { return }

        if recordingStartFrameTime == nil {
            recordingStartFrameTime = frameTime
        }
        let elapsed = max(0, frameTime - (recordingStartFrameTime ?? frameTime)
                          - pausedAccumulated)

        // Pose-driven progression: the state machine decides the current
        // stage from the measured relative pose, never from elapsed time.
        let output = guidance.update(ProtocolGuidanceInput(
            timestamp: frameTime,
            faceTracked: faceTracked,
            yawDegrees: relativeEulerUser?.yawDegrees,
            pitchDegrees: relativeEulerUser?.pitchDegrees,
            angularVelocityDegPerSec: angularVelocity,
            distanceDeviationMeters: deviation,
            lateralInBounds: lateralInBounds,
            phoneStability: stability))
        lastGuidanceOutput = output
        completedDirections = output.completedDirections

        if output.protocolPhase != lastPhase {
            lastPhase = output.protocolPhase
            let cb = onPhaseChange
            let phase = output.protocolPhase
            DispatchQueue.main.async { cb?(phase) }
        }

        let quat = pose?.rotation
        let sample = MeasurementSample(
            timestampUnix: Date().timeIntervalSince1970,
            arFrameTimestamp: frameTime,
            sessionElapsedSeconds: elapsed,
            protocolPhase: output.protocolPhase.rawValue,
            cameraTransform: FaceTransformCalculator.flatten(worldFromCamera),
            faceAnchorTransform: worldFromFace.map(FaceTransformCalculator.flatten),
            cameraFromFaceTransform: pose.map { FaceTransformCalculator.flatten($0.cameraFromFace) },
            translationX: pose.map { Double($0.translation.x) },
            translationY: pose.map { Double($0.translation.y) },
            translationZ: pose.map { Double($0.translation.z) },
            forwardDepthMeters: pose?.forwardDepthMeters,
            headReferenceDistanceMeters: pose?.headReferenceDistanceMeters,
            trueDepthSurfaceRawMeters: surfaceRaw,
            trueDepthSurfaceMedianFilteredMeters: surfaceMedian,
            trueDepthSurfaceEMAFilteredMeters: surfaceEMA,
            estimatedScreenToFaceMeters: estimatedScreen,
            distanceDeviationFromBaselineMeters: deviation,
            quaternionX: quat.map { Double($0.vector.x) },
            quaternionY: quat.map { Double($0.vector.y) },
            quaternionZ: quat.map { Double($0.vector.z) },
            quaternionW: quat.map { Double($0.vector.w) },
            rawYawDegrees: rawEuler?.yawDegrees,
            rawPitchDegrees: rawEuler?.pitchDegrees,
            rawRollDegrees: rawEuler?.rollDegrees,
            relativeYawDegrees: relativeEulerUser?.yawDegrees,
            relativePitchDegrees: relativeEulerUser?.pitchDegrees,
            relativeRollDegrees: relativeEulerUser?.rollDegrees,
            headAngularVelocityDegPerSec: angularVelocity,
            phoneRotationRateMagnitudeRadPerSec: motion?.rotationRateMagnitude,
            phoneAccelerationMagnitudeG: motion?.userAccelerationMagnitude,
            phoneAttitudeChangeDegrees: motion?.attitudeChangeFromReferenceDegrees,
            trueDepthValidPixelCount: depthStats?.validPixelCount,
            trueDepthValidPixelRatio: depthStats?.validRatio,
            trackingValid: faceTracked,
            phoneStable: stability == .stable,
            distanceStable: distanceStable,
            sampleValid: validation.isValid,
            confidence: validation.confidence,
            rejectionReasons: validation.reasons.map { $0.rawValue },
            coverageFraction: output.coverage?.coveredFraction,
            coverageCellColumn: output.coverage?.currentColumn,
            coverageCellRow: output.coverage?.currentRow)
        recorder.add(sample)

        // Completion comes from the state machine (all stages genuinely
        // performed), not from a clock running out.
        if output.isComplete {
            finishRecording()
        }
    }

    private func finishRecording() {
        guard let recorder else { return }
        let elapsed: Double
        if let start = recordingStartFrameTime {
            elapsed = max(0, lastFrameTimestamp - start - pausedAccumulated)
        } else {
            elapsed = 0
        }

        var metadata = SessionMetadata()
        metadata.screenWidthPoints = screenWidthPoints
        metadata.screenHeightPoints = screenHeightPoints
        metadata.screenScale = screenScale
        metadata.dotCenterXPoints = Double(dotCenter.x)
        metadata.dotCenterYPoints = Double(dotCenter.y)
        metadata.recordingMode = recordingMode.rawValue
        metadata.startedAt = recorder.startedAt
        metadata.cameraBehindScreenOffsetMeters = cameraBehindScreenOffsetMeters
        metadata.screenOffsetCalibrated = screenOffsetCalibrated

        let session = recorder.finish(metadata: metadata,
                                      configuration: config,
                                      neutralPose: neutralPose,
                                      durationSeconds: elapsed,
                                      stageTransitions: guidance?.transitions ?? [])
        self.recorder = nil
        self.guidance = nil
        self.lastGuidanceOutput = nil
        self.recordingStartFrameTime = nil
        self.pausedAccumulated = 0
        self.pauseBeganAt = nil
        stage = .finished

        let cb = onRecordingFinished
        DispatchQueue.main.async { cb?(session) }
    }

    // MARK: - Offset calibration

    private func processOffsetCalibration(frameTime: TimeInterval,
                                          surfaceRaw: Double?,
                                          stability: PhoneStability) {
        guard offsetCalibrationSamples != nil else { return }

        if let surface = surfaceRaw, stability != .excessive {
            offsetCalibrationSamples?.append(surface)
        }

        let count = offsetCalibrationSamples?.count ?? 0
        if count >= config.offsetCalibrationSampleCount {
            let median = Statistics.median(offsetCalibrationSamples ?? []) ?? 0
            let offset = ScreenDistanceCalibrator.computeOffset(
                medianCameraDepthMeters: median,
                referenceScreenDistanceMeters: offsetCalibrationReferenceMeters)
            offsetCalibrationSamples = nil
            offsetCalibrationStartTime = nil
            cameraBehindScreenOffsetMeters = offset
            screenOffsetCalibrated = true
            let cb = onOffsetCalibrationFinished
            DispatchQueue.main.async { cb?(.success(offset)) }
        } else if let start = offsetCalibrationStartTime, frameTime - start > 15 {
            offsetCalibrationSamples = nil
            offsetCalibrationStartTime = nil
            let cb = onOffsetCalibrationFinished
            DispatchQueue.main.async {
                cb?(.failure(.notEnoughStableSamples))
            }
        }
    }

    // MARK: - Snapshot publishing

    private func publishSnapshot(frame: ARFrame, frameTime: TimeInterval,
                                 pose: CameraRelativeFacePose?,
                                 worldFromCamera: simd_float4x4,
                                 worldFromFace: simd_float4x4?,
                                 faceTracked: Bool,
                                 rawEuler: EulerAngles?,
                                 relativeQuat: simd_quatf?,
                                 relativeEulerRaw: EulerAngles?,
                                 relativeEulerUser: EulerAngles?,
                                 angularVelocity: Double?,
                                 depthDataPresent: Bool,
                                 depthStats: DepthROIStatistics?,
                                 surfaceRaw: Double?, surfaceMedian: Double?,
                                 surfaceEMA: Double?, estimatedScreen: Double?,
                                 baseline: Double?, deviation: Double?,
                                 distanceStable: Bool,
                                 motion: DeviceMotionMonitor.Snapshot?,
                                 stability: PhoneStability,
                                 validation: ValidationResult,
                                 alignment: FaceAlignmentState) {
        var s = MeasurementSnapshot()
        s.stage = stage
        s.faceTracked = faceTracked
        s.trackingStateDescription = trackingStateDescription
        s.interrupted = interrupted
        s.sessionErrorMessage = sessionErrorMessage
        s.frameRateHz = frameRateEMA
        s.recordingMode = recordingMode

        // Protocol state.
        switch stage {
        case .capturingNeutral:
            s.currentPhase = .neutralCapture
            s.phaseInstruction = ProtocolPhase.neutralCapture.instruction
            if let collector = neutralCollector {
                let elapsed = frameTime - collector.startedAtFrameTime
                s.neutralCaptureProgress = min(1, elapsed / config.neutralCaptureDurationSeconds)
            }
        case .recording, .paused:
            if let start = recordingStartFrameTime {
                var elapsed = lastFrameTimestamp - start - pausedAccumulated
                if stage == .paused, let began = pauseBeganAt {
                    elapsed = began - start - pausedAccumulated
                }
                s.recordingElapsedSeconds = max(0, elapsed)
            }
            if let output = lastGuidanceOutput {
                s.currentPhase = output.protocolPhase
                s.phaseInstruction = output.instruction
                s.phaseSymbolName = output.direction?.symbolName
                s.phaseProgress = output.holdProgress
                s.guidance = GuidanceUIState(output: output)
            } else {
                s.currentPhase = .center
                s.phaseInstruction = ProtocolPhase.center.instruction
            }
        case .finished:
            s.currentPhase = .complete
            s.phaseInstruction = ProtocolPhase.complete.instruction
        default:
            s.currentPhase = .idle
            s.phaseInstruction = ProtocolPhase.idle.instruction
        }
        s.acceptedSampleCount = recorder?.acceptedCount ?? 0
        s.rejectedSampleCount = recorder?.rejectedCount ?? 0

        // Cosmetic live readout of how far the head is along the current
        // phase's axis (advancement itself is decided by the controller).
        s.directionProgress = HeadDirectionProgress.evaluate(
            phase: s.currentPhase,
            yawDegrees: relativeEulerUser?.yawDegrees,
            pitchDegrees: relativeEulerUser?.pitchDegrees,
            config: config)
        s.completedDirections = completedDirections

        // Head-position boundary (computed once in process(), from tracking
        // data only).
        s.alignment = alignment

        // Phone motion.
        s.phoneStability = stability
        if let m = motion {
            s.phoneRotationRate = m.rotationRate
            s.phoneUserAcceleration = m.userAcceleration
            s.phoneGravity = m.gravity
            s.phoneAttitudeChangeDegrees = m.attitudeChangeFromReferenceDegrees
        }

        // Distances.
        s.forwardDepthMeters = pose?.forwardDepthMeters
        s.headReferenceDistanceMeters = pose?.headReferenceDistanceMeters
        s.trueDepthSurfaceRawMeters = surfaceRaw
        s.trueDepthSurfaceMedianFilteredMeters = surfaceMedian
        s.trueDepthSurfaceEMAFilteredMeters = surfaceEMA
        s.estimatedScreenToFaceMeters = estimatedScreen
        s.screenOffsetCalibrated = screenOffsetCalibrated
        s.cameraBehindScreenOffsetMeters = cameraBehindScreenOffsetMeters
        s.baselineDistanceMeters = baseline
        s.distanceDeviationMeters = deviation
        s.distanceWarning = !distanceStable
        s.trueDepthAvailableThisFrame = depthDataPresent
        s.trueDepthEverAvailable = trueDepthEverAvailable

        // Depth debug info.
        if let stats = depthStats {
            s.depthValidPixelCount = stats.validPixelCount
            s.depthTotalPixelCount = stats.totalPixelCount
            s.depthValidPixelRatio = stats.validRatio
            s.depthMapWidth = stats.depthMapWidth
            s.depthMapHeight = stats.depthMapHeight
            s.depthFormatDescription = stats.pixelFormatDescription
            s.depthROIDescription = String(format: "origin (%d, %d), %dx%d px @ proj (%.0f, %.0f)",
                                           stats.roiOriginX, stats.roiOriginY,
                                           stats.roiWidth, stats.roiHeight,
                                           stats.projectedImageX, stats.projectedImageY)
            s.depthConsistent = stats.consistentWithHeadReference
            if stats.depthMapWidth > 0, stats.depthMapHeight > 0 {
                // Depth-map (landscape) rect -> portrait-preview normalized
                // rect for the 90° clockwise-rotated debug preview.
                let nx = Double(stats.roiOriginX) / Double(stats.depthMapWidth)
                let ny = Double(stats.roiOriginY) / Double(stats.depthMapHeight)
                let nw = Double(stats.roiWidth) / Double(stats.depthMapWidth)
                let nh = Double(stats.roiHeight) / Double(stats.depthMapHeight)
                s.debugROIRectNormalized = CGRect(x: 1.0 - ny - nh, y: nx,
                                                  width: nh, height: nw)
            }
        }

        // Orientation.
        s.hasNeutralPose = neutralPose != nil
        s.rawEuler = rawEuler
        s.relativeEuler = relativeEulerUser
        s.relativeEulerRaw = relativeEulerRaw
        s.headAngularVelocityDegPerSec = angularVelocity

        // Debug transforms.
        s.worldFromCamera = worldFromCamera
        s.worldFromFace = worldFromFace
        s.cameraFromFace = pose?.cameraFromFace
        s.translation = pose?.translation
        s.rawQuaternion = pose?.rotation
        s.neutralQuaternion = neutralPose?.simdQuaternion
        s.relativeQuaternion = relativeQuat

        // Validation.
        s.sampleValid = validation.isValid
        s.confidence = validation.confidence
        s.rejectionReasons = validation.reasons.map { $0.rawValue }

        // Offset calibration progress.
        if let samples = offsetCalibrationSamples {
            s.offsetCalibrationActive = true
            s.offsetCalibrationProgress = min(1, Double(samples.count)
                                              / Double(config.offsetCalibrationSampleCount))
        }

        // Debug preview (never persisted). Front-camera image rotated 90° CW
        // for portrait display; orientation is a debug convenience only.
        if debugPreviewEnabled, frameTime - lastPreviewTime > 0.4 {
            lastPreviewTime = frameTime
            let ci = CIImage(cvPixelBuffer: frame.capturedImage).oriented(.right)
            if let cg = ciContext.createCGImage(ci, from: ci.extent) {
                s.debugPreviewImage = UIImage(cgImage: cg)
            }
        }

        let cb = onSnapshot
        DispatchQueue.main.async { cb?(s) }
    }
}
