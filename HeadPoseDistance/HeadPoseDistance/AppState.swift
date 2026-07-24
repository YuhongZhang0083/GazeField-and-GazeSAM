import Foundation

/// Top-level navigation phase of the app.
enum AppPhase {
    case deviceCheck
    case instructions
    case measurement
    case results
}

/// Stage inside the live-measurement screen. Driven by the pipeline.
enum MeasurementStage: String {
    /// Live preview: tracking runs, values display, nothing is recorded.
    case preview
    /// The 2-second neutral-pose capture window is running.
    case capturingNeutral
    /// A neutral pose exists; ready to start the movement recording.
    case neutralReady
    /// The guided head-movement recording is running.
    case recording
    /// Recording paused by the user (or an interruption).
    case paused
    /// Recording finished; results are available.
    case finished
}

enum CameraPermissionState {
    case notDetermined
    case granted
    case denied
}
