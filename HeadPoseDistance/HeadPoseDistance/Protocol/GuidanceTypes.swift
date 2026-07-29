import Foundation

/// Types shared by every recording protocol (the eight-spoke
/// `GuidedMovementController` and the `SpiralSweepController`).
///
/// They live at file scope rather than nested in one controller so both
/// protocols emit the SAME transition log and the SAME per-frame output — the
/// pipeline, snapshot, and export layers stay mode-agnostic. Compatibility
/// aliases at the bottom keep the original
/// `GuidedMovementController.StateKind` spellings valid.

/// Which recording protocol a session used. Exported in the session metadata
/// so a CSV is always self-describing.
enum RecordingMode: String, Codable, CaseIterable, Identifiable {
    /// Eight discrete directions, each reached from neutral and held.
    /// Sparse in the interior — kept as a validation / comparison protocol.
    case eightSpoke = "eight_spoke"
    /// Free head movement with no target to match; the session ends when a
    /// coverage grid over the (yaw, pitch) field has been filled.
    case freeExploration = "free_exploration"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .eightSpoke: return "8-Spoke"
        case .freeExploration: return "Free Explore"
        }
    }

    var shortDescription: String {
        switch self {
        case .eightSpoke:
            return "Eight held directions — validation set"
        case .freeExploration:
            return "Move freely until the coverage grid fills — gaze-field set"
        }
    }
}

/// Sub-state of a recording protocol. Shared vocabulary: the eight-spoke
/// protocol never enters the sweep states and vice versa, but both use the
/// neutral and pause states, so a transition log reads the same either way.
enum GuidanceStateKind: String, Codable, Equatable {
    // Eight-spoke states.
    case instructingDirection = "instructing_direction"
    case movingTowardTarget = "moving_toward_target"
    case holdingTargetPose = "holding_target_pose"
    // Shared states.
    case returningToNeutral = "returning_to_neutral"
    case holdingNeutral = "holding_neutral"
    case pausedForTracking = "paused_for_tracking"
    case pausedForDistance = "paused_for_distance"
    case pausedForPhoneMotion = "paused_for_phone_motion"
    case complete
    /// Free head movement, accruing coverage.
    case exploring
}

/// Why a state transition happened. Every transition is recorded.
enum GuidanceTransitionReason: String, Codable {
    case recordingStarted = "recording_started"
    case movementStarted = "movement_started"
    case targetReached = "target_reached"
    case holdBroken = "hold_broken"
    case holdCompleted = "hold_completed"
    case reachedNeutral = "reached_neutral"
    case leftNeutral = "left_neutral"
    case neutralHoldCompleted = "neutral_hold_completed"
    case allStagesComplete = "all_stages_complete"
    case stageTimeout = "stage_timeout"
    case trackingLost = "tracking_lost"
    case trackingRecovered = "tracking_recovered"
    case distanceOutOfRange = "distance_out_of_range"
    case distanceRecovered = "distance_recovered"
    case phoneMotionExcessive = "phone_motion_excessive"
    case phoneMotionEnded = "phone_motion_ended"
    // Free-exploration reasons.
    case explorationStarted = "exploration_started"
    case coverageComplete = "coverage_complete"
}

/// One recorded transition, exported with the session.
struct ProtocolTransition: Codable, Equatable {
    var sessionElapsedSeconds: Double
    var fromState: String
    var toState: String
    var stagePhase: String
    var reason: String
}

/// Non-blocking corrective feedback shown near the fixation dot.
enum GuidanceFeedback: Equatable {
    case wrongDirection
    case tooFast
    case offAxis

    var message: String {
        switch self {
        case .wrongDirection: return "Other way — follow the arrow"
        case .tooFast: return "Move more slowly"
        case .offAxis: return "Drifting off-axis — follow the arrow"
        }
    }
}

/// Per-frame input, all values neutral-relative / already filtered by the
/// measurement pipeline.
struct ProtocolGuidanceInput {
    var timestamp: TimeInterval
    var faceTracked: Bool
    var yawDegrees: Double?
    var pitchDegrees: Double?
    var angularVelocityDegPerSec: Double?
    /// Head-reference distance deviation from the neutral baseline (meters).
    var distanceDeviationMeters: Double?
    /// False when the face has slid outside the fixed lateral/vertical
    /// bounds captured at neutral. Treated the same as a distance drift:
    /// progression pauses until the face returns.
    var lateralInBounds: Bool = true
    var phoneStability: PhoneStability
}

/// Live coverage state of a free-exploration session, for the grid view and
/// the recorded samples.
struct ExplorationGuidanceState: Equatable {
    var columns: Int
    var rows: Int
    /// Row-major 0…1 fill per cell, top row first.
    var cellFill: [Double]
    /// Row-major flags: false for cells outside the elliptical field, which are
    /// drawn faintly and are not required.
    var cellRequired: [Bool]
    var coveredCells: Int
    var requiredCells: Int
    var coveredFraction: Double
    /// Cell the head is in right now, nil outside the field or before the
    /// exploration phase.
    var currentColumn: Int?
    var currentRow: Int?
    /// True on the single frame a required cell filled up — drives one haptic
    /// tick, so progress is felt without looking away from the dot.
    var completedCellThisFrame: Bool
}

/// Everything the UI and the sample labeler need for the current frame.
struct ProtocolGuidanceOutput: Equatable {
    var state: GuidanceStateKind
    /// Direction being worked on (eight-spoke only), nil once complete.
    var direction: ProtocolPhase?
    /// Phase label recorded on samples (up/center/sweep/…).
    var protocolPhase: ProtocolPhase
    /// Short instruction, phrased for display next to the fixation dot.
    var instruction: String
    var feedback: GuidanceFeedback?
    /// 0…1 progress of the active hold (target or neutral), else 0.
    var holdProgress: Double
    /// 0…1 progress toward the target angle (eight-spoke), else 0.
    var approachProgress: Double
    var stageIndex: Int
    var stageCount: Int
    var completedDirections: Set<ProtocolPhase>
    var isComplete: Bool
    var isPaused: Bool
    /// Present only in free-exploration mode.
    var coverage: ExplorationGuidanceState?
}

/// A recording protocol the pipeline can drive. Both implementations are pure
/// Swift + Foundation: deterministic given a sequence of inputs, and testable
/// without ARKit.
protocol ProtocolControlling: AnyObject {
    var transitions: [ProtocolTransition] { get }
    func update(_ input: ProtocolGuidanceInput) -> ProtocolGuidanceOutput
}

// MARK: - Source-compatibility aliases

extension GuidedMovementController {
    typealias StateKind = GuidanceStateKind
    typealias TransitionReason = GuidanceTransitionReason
    typealias StageTransition = ProtocolTransition
    typealias Feedback = GuidanceFeedback
    typealias GuidanceInput = ProtocolGuidanceInput
    typealias GuidanceOutput = ProtocolGuidanceOutput
}
