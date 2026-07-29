import Foundation
import SwiftUI
import AVFoundation
import ARKit
import Combine

/// Files produced by an export, ready for the share sheet.
struct ExportedFile: Identifiable {
    let id = UUID()
    let url: URL
    let label: String
}

/// Main-actor view model. Owns the AR manager, motion monitor, and pipeline;
/// forwards control actions onto the pipeline queue and publishes pipeline
/// snapshots to SwiftUI.
@MainActor
final class MeasurementViewModel: ObservableObject {

    // MARK: Published UI state
    @Published private(set) var snapshot = MeasurementSnapshot.initial
    @Published var appPhase: AppPhase = .deviceCheck
    @Published private(set) var cameraPermission: CameraPermissionState = .notDetermined
    @Published private(set) var lastSession: RecordedSession?
    @Published var neutralCaptureMessage: String?
    @Published var offsetCalibrationMessage: String?
    @Published private(set) var screenOffsetMeters: Double = 0
    @Published private(set) var screenOffsetCalibrated = false
    @Published var showDebugView = false
    @Published var showCalibrationSheet = false
    /// Protocol used for the next recording. Defaults to free exploration —
    /// the coverage-driven protocol the gaze-field fit needs; the eight-spoke
    /// protocol remains selectable as a comparison / validation set.
    @Published var recordingMode: RecordingMode = .freeExploration
    @Published private(set) var exportedFiles: [ExportedFile] = []
    @Published var exportErrorMessage: String?

    // MARK: Device capabilities (fixed at launch)
    let isFaceTrackingSupported = ARFaceTrackingManager.isFaceTrackingSupported
    let isRunningOnSimulator: Bool = {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }()

    let config = MeasurementConfig.default

    // MARK: Private components
    private let sessionQueue = DispatchQueue(label: "com.headposedistance.arsession")
    private let motionMonitor = DeviceMotionMonitor()
    private let manager: ARFaceTrackingManager
    private let pipeline: MeasurementPipeline
    private let haptics = UIImpactFeedbackGenerator(style: .medium)
    private let targetHaptics = UINotificationFeedbackGenerator()

    /// Live camera preview renderer — DEBUG VIEW ONLY, disabled by default.
    /// The normal measurement workflow never displays the camera image.
    /// Nil when Metal is unavailable (e.g. some simulators).
    let previewRenderer = CameraPreviewRenderer.make()

    /// Directions whose completion haptic has already fired this recording.
    private var lastCompletedCount = 0
    /// Phase currently in the on-target zone (entry haptic already fired).
    private var lastHapticPhase: ProtocolPhase?
    /// Coverage-cell count at the last haptic tick, so a tick fires once per
    /// newly completed cell even though snapshots arrive at ~15 Hz.
    private var lastCoveredCellCount = 0

    init() {
        manager = ARFaceTrackingManager(callbackQueue: sessionQueue)
        pipeline = MeasurementPipeline(queue: sessionQueue,
                                       config: config,
                                       motionMonitor: motionMonitor)
        pipeline.previewRenderer = previewRenderer
        let stored = ScreenDistanceCalibrator.loadOffset()
        screenOffsetMeters = stored.offsetMeters
        screenOffsetCalibrated = stored.calibrated
        wirePipeline()
        refreshCameraPermission()
    }

    private func wirePipeline() {
        let pipeline = self.pipeline
        manager.onFrame = { [weak pipeline] frame in
            pipeline?.process(frame: frame)
        }
        manager.onEvent = { [weak pipeline] event in
            switch event {
            case .interrupted:
                pipeline?.noteInterruption(true)
            case .interruptionEnded:
                pipeline?.noteInterruption(false)
            case .failed(let message):
                pipeline?.noteSessionError(message)
            case .trackingStateChanged(let description):
                pipeline?.noteTrackingState(description)
            }
        }

        pipeline.onSnapshot = { [weak self] snap in
            guard let self else { return }
            self.snapshot = snap
            self.fireTargetHapticIfNeeded(snap)
        }
        pipeline.onNeutralResult = { [weak self] result in
            switch result {
            case .success:
                self?.neutralCaptureMessage = nil
            case .failure(let error):
                self?.neutralCaptureMessage = error.errorDescription
            }
        }
        pipeline.onRecordingFinished = { [weak self] session in
            guard let self else { return }
            self.lastSession = session
            self.exportedFiles = []
            self.appPhase = .results
        }
        pipeline.onPhaseChange = { [weak self] _ in
            self?.haptics.impactOccurred()
        }
        pipeline.onOffsetCalibrationFinished = { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let offset):
                ScreenDistanceCalibrator.save(offsetMeters: offset)
                self.screenOffsetMeters = offset
                self.screenOffsetCalibrated = true
                self.offsetCalibrationMessage = String(
                    format: "Offset calibrated: %.1f mm (camera depth minus screen distance).",
                    offset * 1000)
            case .failure(let error):
                self.offsetCalibrationMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Permissions

    func refreshCameraPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: cameraPermission = .granted
        case .notDetermined: cameraPermission = .notDetermined
        default: cameraPermission = .denied
        }
    }

    func requestCameraPermission() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            Task { @MainActor [weak self] in
                self?.cameraPermission = granted ? .granted : .denied
            }
        }
    }

    // MARK: - Navigation / lifecycle

    func proceedToInstructions() {
        appPhase = .instructions
    }

    func beginMeasurement() {
        guard isFaceTrackingSupported, cameraPermission == .granted else { return }
        appPhase = .measurement
        motionMonitor.start()
        manager.start()
    }

    func stopSession() {
        manager.stop()
        motionMonitor.stop()
        previewRenderer?.clear()
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background, .inactive:
            sessionQueue.async { [pipeline] in pipeline.noteInterruption(true) }
        case .active:
            sessionQueue.async { [pipeline] in pipeline.noteInterruption(false) }
        @unknown default:
            break
        }
    }

    /// Reports the measured center-dot position and usable screen geometry
    /// (recorded as session metadata).
    func reportScreenGeometry(dotCenterGlobal: CGPoint, screenSize: CGSize, scale: CGFloat) {
        sessionQueue.async { [pipeline] in
            pipeline.updateScreenInfo(widthPoints: Double(screenSize.width),
                                      heightPoints: Double(screenSize.height),
                                      scale: Double(scale),
                                      dotCenter: dotCenterGlobal)
        }
    }

    // MARK: - Protocol control

    func captureNeutral() {
        neutralCaptureMessage = nil
        sessionQueue.async { [pipeline] in pipeline.beginNeutralCapture() }
    }

    func recaptureNeutral() {
        neutralCaptureMessage = nil
        sessionQueue.async { [pipeline] in pipeline.resetNeutral() }
    }

    func startRecording() {
        let mode = recordingMode
        sessionQueue.async { [pipeline] in pipeline.startRecording(mode: mode) }
    }

    func pauseRecording() {
        sessionQueue.async { [pipeline] in pipeline.pauseRecording() }
    }

    func resumeRecording() {
        sessionQueue.async { [pipeline] in pipeline.resumeRecording() }
    }

    func stopRecording() {
        sessionQueue.async { [pipeline] in pipeline.stopRecording() }
    }

    func restartSession() {
        lastSession = nil
        exportedFiles = []
        appPhase = .measurement
        sessionQueue.async { [pipeline] in pipeline.restartSession() }
    }

    // MARK: - Guidance feedback

    /// Haptic confirmations that never require looking away from the dot:
    /// a light tap when the head first enters the target zone (hold started),
    /// and a success buzz when a directional stage genuinely completes.
    private func fireTargetHapticIfNeeded(_ snap: MeasurementSnapshot) {
        guard snap.stage == .recording else {
            if snap.stage == .preview || snap.stage == .finished {
                lastCompletedCount = 0
                lastHapticPhase = nil
                lastCoveredCellCount = 0
            }
            return
        }

        // Free exploration: one tick per newly covered cell. This is the only
        // feedback that does not require looking away from the fixation dot,
        // so it carries the progress signal the coverage grid shows visually.
        if let coverage = snap.guidance?.coverage {
            if coverage.coveredCells > lastCoveredCellCount {
                lastCoveredCellCount = coverage.coveredCells
                haptics.impactOccurred()
            } else if coverage.coveredCells < lastCoveredCellCount {
                lastCoveredCellCount = coverage.coveredCells
            }
        }

        if let guidance = snap.guidance {
            if guidance.state == .holdingTargetPose {
                if lastHapticPhase != snap.currentPhase {
                    lastHapticPhase = snap.currentPhase
                    haptics.impactOccurred()
                }
            } else {
                lastHapticPhase = nil
            }
        }

        if snap.completedDirections.count > lastCompletedCount {
            lastCompletedCount = snap.completedDirections.count
            targetHaptics.notificationOccurred(.success)
        }
    }

    // MARK: - Debug preview (debug view only, disabled by default)

    func setDebugPreview(_ enabled: Bool) {
        previewRenderer?.isEnabled = enabled
        if !enabled { previewRenderer?.clear() }
        sessionQueue.async { [pipeline] in pipeline.setDebugPreviewEnabled(enabled) }
    }

    // MARK: - Screen-offset calibration

    func beginOffsetCalibration(referenceCentimeters: Double) {
        offsetCalibrationMessage = nil
        let meters = referenceCentimeters / 100.0
        sessionQueue.async { [pipeline] in
            pipeline.beginOffsetCalibration(referenceScreenDistanceMeters: meters)
        }
    }

    func resetOffsetCalibration() {
        ScreenDistanceCalibrator.reset()
        screenOffsetMeters = 0
        screenOffsetCalibrated = false
        offsetCalibrationMessage = "Offset reset to 0 (uncalibrated)."
        sessionQueue.async { [pipeline] in pipeline.resetScreenOffset() }
    }

    // MARK: - Export

    /// Writes CSV and JSON exports for the last session and returns them for
    /// the share sheet. Files contain numerical measurements only.
    func exportLastSession(includeRejected: Bool) {
        guard let session = lastSession else { return }
        exportErrorMessage = nil
        let stamp = ISO8601DateFormatter().string(from: session.metadata.startedAt)
            .replacingOccurrences(of: ":", with: "-")
        let baseName = "HeadPoseDistance_\(stamp)_\(session.metadata.sessionID.uuidString.prefix(8))"
        let directory = FileManager.default.temporaryDirectory

        do {
            var files: [ExportedFile] = []
            let cleanCSV = try CSVExporter.write(samples: session.acceptedSamples,
                                                 to: directory,
                                                 filename: "\(baseName).csv")
            files.append(ExportedFile(url: cleanCSV, label: "CSV (accepted samples)"))

            if includeRejected {
                let debugCSV = try CSVExporter.write(
                    samples: session.acceptedSamples + session.rejectedSamples,
                    to: directory,
                    filename: "\(baseName)_debug.csv")
                files.append(ExportedFile(url: debugCSV, label: "CSV (debug, incl. rejected)"))
            }

            let json = try JSONExporter.write(session: session,
                                              includeRejected: includeRejected,
                                              to: directory,
                                              filename: "\(baseName).json")
            files.append(ExportedFile(url: json, label: "JSON (full session)"))
            exportedFiles = files
        } catch {
            exportErrorMessage = "Export failed: \(error.localizedDescription)"
        }
    }
}
