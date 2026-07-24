import Foundation

/// Phase of the guided head-movement protocol. These are movement
/// INSTRUCTIONS only — the user's eyes stay on the single fixed center dot
/// at all times; no additional fixation targets are ever shown.
enum ProtocolPhase: String, Codable, CaseIterable {
    case idle
    case neutralCapture = "neutral_capture"
    case center
    case up
    case down
    case left
    case right
    case upperLeft = "upper_left"
    case upperRight = "upper_right"
    case lowerLeft = "lower_left"
    case lowerRight = "lower_right"
    case complete

    /// Instruction text shown during recording. Deliberately phrased as a
    /// head-movement instruction, never as a place to look.
    var instruction: String {
        switch self {
        case .idle: return "Look at the red dot"
        case .neutralCapture: return "Look at the red dot and hold your head still"
        case .center: return "Return your head to center — keep looking at the red dot"
        case .up: return "Slowly rotate your head UP — keep your eyes on the red dot"
        case .down: return "Slowly rotate your head DOWN — keep your eyes on the red dot"
        case .left: return "Slowly turn your head LEFT — keep your eyes on the red dot"
        case .right: return "Slowly turn your head RIGHT — keep your eyes on the red dot"
        case .upperLeft: return "Rotate your head UPPER-LEFT — keep your eyes on the red dot"
        case .upperRight: return "Rotate your head UPPER-RIGHT — keep your eyes on the red dot"
        case .lowerLeft: return "Rotate your head LOWER-LEFT — keep your eyes on the red dot"
        case .lowerRight: return "Rotate your head LOWER-RIGHT — keep your eyes on the red dot"
        case .complete: return "Done — recording complete"
        }
    }

    /// SF Symbol arrow for the direction indicator (text-adjacent, not a
    /// fixation target).
    var symbolName: String? {
        switch self {
        case .center: return "dot.circle"
        case .up: return "arrow.up"
        case .down: return "arrow.down"
        case .left: return "arrow.left"
        case .right: return "arrow.right"
        case .upperLeft: return "arrow.up.left"
        case .upperRight: return "arrow.up.right"
        case .lowerLeft: return "arrow.down.left"
        case .lowerRight: return "arrow.down.right"
        case .complete: return "checkmark.circle"
        case .idle, .neutralCapture: return nil
        }
    }
}

struct ProtocolStep: Equatable {
    var phase: ProtocolPhase
    var duration: TimeInterval
}

/// Time-based schedule for the guided recording:
/// center → up → center → down → center → left → center → right → center →
/// upper-left → center → upper-right → center → lower-left → center →
/// lower-right → center.
///
/// Elapsed recording time maps deterministically onto a step. Instructions
/// advance on this clock, but sample data records the ACTUAL continuous
/// yaw/pitch/roll trajectory with the active phase label — the app never
/// claims a direction was achieved based on elapsed time alone.
struct RecordingProtocolSchedule: Equatable {
    let steps: [ProtocolStep]
    let totalDuration: TimeInterval

    init(steps: [ProtocolStep]) {
        self.steps = steps
        self.totalDuration = steps.reduce(0) { $0 + $1.duration }
    }

    static func standard(config: MeasurementConfig) -> RecordingProtocolSchedule {
        let directions: [ProtocolPhase] = [.up, .down, .left, .right,
                                           .upperLeft, .upperRight,
                                           .lowerLeft, .lowerRight]
        var steps: [ProtocolStep] = [ProtocolStep(phase: .center,
                                                  duration: config.centerHoldSeconds)]
        for d in directions {
            steps.append(ProtocolStep(phase: d, duration: config.directionHoldSeconds))
            steps.append(ProtocolStep(phase: .center, duration: config.centerHoldSeconds))
        }
        return RecordingProtocolSchedule(steps: steps)
    }

    struct Position: Equatable {
        var stepIndex: Int
        var phase: ProtocolPhase
        var stepElapsed: TimeInterval
        var stepDuration: TimeInterval
        var stepProgress: Double
    }

    /// Step for a given elapsed time, or nil once the schedule is complete.
    func position(atElapsed elapsed: TimeInterval) -> Position? {
        guard elapsed >= 0 else {
            guard let first = steps.first else { return nil }
            return Position(stepIndex: 0, phase: first.phase, stepElapsed: 0,
                            stepDuration: first.duration, stepProgress: 0)
        }
        var accumulated: TimeInterval = 0
        for (index, step) in steps.enumerated() {
            if elapsed < accumulated + step.duration {
                let stepElapsed = elapsed - accumulated
                return Position(stepIndex: index,
                                phase: step.phase,
                                stepElapsed: stepElapsed,
                                stepDuration: step.duration,
                                stepProgress: step.duration > 0 ? stepElapsed / step.duration : 1)
            }
            accumulated += step.duration
        }
        return nil
    }
}
