import Foundation

/// Pose-driven state machine for the guided head-movement protocol.
///
/// The controller replaces the old fixed-time schedule: every stage advances
/// **only** because the measured neutral-relative pose satisfied that stage's
/// completion criteria — never because a timer expired. Timers are used solely
/// for hold requirements (pose must *stay* correct), temporal hysteresis, and
/// a generous failure/retry timeout.
///
/// Pure Swift + Foundation, fully deterministic given a sequence of
/// `GuidanceInput`s, and unit-testable without ARKit.
///
/// State graph per directional stage (up, down, …, lower-right):
///
///     instructingDirection ──movementStarted──▶ movingTowardTarget
///     movingTowardTarget ──targetReached──▶ holdingTargetPose
///     holdingTargetPose ──holdBroken──▶ movingTowardTarget
///     holdingTargetPose ──holdCompleted──▶ returningToNeutral
///     returningToNeutral ──reachedNeutral──▶ holdingNeutral
///     holdingNeutral ──leftNeutral──▶ returningToNeutral
///     holdingNeutral ──neutralHoldCompleted──▶ next stage / complete
///
/// plus pause states (tracking / distance / phone motion) that suspend the
/// graph and return to a safe sub-state on resume, and a per-stage timeout
/// that records a failure transition and retries the same stage.
final class GuidedMovementController {

    // MARK: - Public types

    /// Sub-state of the guided protocol.
    enum StateKind: String, Codable, Equatable {
        case instructingDirection = "instructing_direction"
        case movingTowardTarget = "moving_toward_target"
        case holdingTargetPose = "holding_target_pose"
        case returningToNeutral = "returning_to_neutral"
        case holdingNeutral = "holding_neutral"
        case pausedForTracking = "paused_for_tracking"
        case pausedForDistance = "paused_for_distance"
        case pausedForPhoneMotion = "paused_for_phone_motion"
        case complete
    }

    /// Why a state transition happened. Every transition is recorded.
    enum TransitionReason: String, Codable {
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
    }

    /// One recorded transition, exported with the session.
    struct StageTransition: Codable, Equatable {
        var sessionElapsedSeconds: Double
        var fromState: String
        var toState: String
        var stagePhase: String
        var reason: String
    }

    /// Non-blocking corrective feedback shown near the fixation dot.
    enum Feedback: Equatable {
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
    struct GuidanceInput {
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

    /// Everything the UI and the sample labeler need for the current frame.
    struct GuidanceOutput: Equatable {
        var state: StateKind
        /// Direction being worked on, nil once complete.
        var direction: ProtocolPhase?
        /// Phase label recorded on samples (up/center/…): preserved format.
        var protocolPhase: ProtocolPhase
        /// Short instruction, phrased for display next to the fixation dot.
        var instruction: String
        var feedback: Feedback?
        /// 0…1 progress of the active hold (target or neutral), else 0.
        var holdProgress: Double
        /// 0…1 progress toward the target angle (mirrors the moving state).
        var approachProgress: Double
        var stageIndex: Int
        var stageCount: Int
        var completedDirections: Set<ProtocolPhase>
        var isComplete: Bool
        var isPaused: Bool
    }

    // MARK: - Configuration

    /// The eight directional stages, in protocol order.
    static let directionSequence: [ProtocolPhase] = [
        .up, .down, .left, .right,
        .upperLeft, .upperRight, .lowerLeft, .lowerRight,
    ]

    private let config: MeasurementConfig

    // MARK: - State

    private(set) var state: StateKind = .returningToNeutral
    private(set) var stageIndex = 0
    private(set) var completedDirections: Set<ProtocolPhase> = []
    private(set) var transitions: [StageTransition] = []
    private(set) var retryCount = 0

    /// Sub-state to restore when a pause lifts. Holds are always demoted one
    /// step (holding → moving, holdingNeutral → returning) so a pause can
    /// never silently count toward a hold requirement.
    private var resumeState: StateKind = .returningToNeutral

    private var startTimestamp: TimeInterval?
    private var lastUpdateTimestamp: TimeInterval?
    private var stageStartTime: TimeInterval?
    private var holdStartTime: TimeInterval?
    private var neutralHoldStartTime: TimeInterval?

    // Distance hysteresis bookkeeping.
    private var distanceOutsideSince: TimeInterval?
    private var distanceInsideSince: TimeInterval?

    init(config: MeasurementConfig) {
        self.config = config
    }

    /// Direction of the stage currently in progress (nil when complete).
    var currentDirection: ProtocolPhase? {
        guard state != .complete, stageIndex < Self.directionSequence.count else { return nil }
        return Self.directionSequence[stageIndex]
    }

    // MARK: - Update

    func update(_ input: GuidanceInput) -> GuidanceOutput {
        let t = input.timestamp
        if startTimestamp == nil {
            startTimestamp = t
            stageStartTime = t
            record(from: state, to: state, at: t, reason: .recordingStarted)
        }

        // A long gap between updates (backgrounding, user pause) must not be
        // credited to hold timers or charged against the stage timeout.
        if let last = lastUpdateTimestamp, t - last > config.updateGapResetSeconds {
            let gap = t - last
            holdStartTime = holdStartTime.map { $0 + gap }
            neutralHoldStartTime = neutralHoldStartTime.map { $0 + gap }
            stageStartTime = stageStartTime.map { $0 + gap }
            distanceOutsideSince = nil
            distanceInsideSince = nil
        }
        lastUpdateTimestamp = t

        guard state != .complete else { return output(input: input) }

        updatePauses(input)

        if !isPausedState(state) {
            updateActive(input)
        }

        return output(input: input)
    }

    // MARK: - Pause handling

    private func isPausedState(_ s: StateKind) -> Bool {
        s == .pausedForTracking || s == .pausedForDistance || s == .pausedForPhoneMotion
    }

    /// Highest-priority failure wins: tracking > phone motion > distance.
    private func updatePauses(_ input: GuidanceInput) {
        let t = input.timestamp

        // --- Tracking ---
        if !input.faceTracked {
            if state != .pausedForTracking {
                pause(to: .pausedForTracking, at: t, reason: .trackingLost)
            }
            return
        }
        if state == .pausedForTracking {
            resume(at: t, reason: .trackingRecovered)
        }

        // --- Phone motion ---
        if input.phoneStability == .excessive {
            if state != .pausedForPhoneMotion {
                pause(to: .pausedForPhoneMotion, at: t, reason: .phoneMotionExcessive)
            }
            return
        }
        if state == .pausedForPhoneMotion {
            resume(at: t, reason: .phoneMotionEnded)
        }

        // --- Alignment: distance drift OR lateral drift out of the fixed
        // bounds (temporal hysteresis in both directions). ---
        let deviation = abs(input.distanceDeviationMeters ?? 0)
        let distanceOut = deviation > config.guidedDistanceBandMeters
        let distanceIn = deviation <= config.guidedDistanceExitBandMeters
        let outOfBounds = distanceOut || !input.lateralInBounds
        let backInBounds = distanceIn && input.lateralInBounds

        if state == .pausedForDistance {
            if backInBounds {
                if distanceInsideSince == nil { distanceInsideSince = t }
                if t - (distanceInsideSince ?? t) >= config.distancePauseExitSeconds {
                    distanceInsideSince = nil
                    resume(at: t, reason: .distanceRecovered)
                }
            } else {
                distanceInsideSince = nil
            }
        } else {
            if outOfBounds {
                if distanceOutsideSince == nil { distanceOutsideSince = t }
                if t - (distanceOutsideSince ?? t) >= config.distancePauseEnterSeconds {
                    distanceOutsideSince = nil
                    pause(to: .pausedForDistance, at: t, reason: .distanceOutOfRange)
                }
            } else {
                distanceOutsideSince = nil
            }
        }
    }

    private func pause(to pauseState: StateKind, at t: TimeInterval, reason: TransitionReason) {
        if !isPausedState(state) {
            // Demote holds so paused time never counts as held time.
            switch state {
            case .holdingTargetPose: resumeState = .movingTowardTarget
            case .holdingNeutral: resumeState = .returningToNeutral
            default: resumeState = state
            }
        }
        transition(to: pauseState, at: t, reason: reason)
        holdStartTime = nil
        neutralHoldStartTime = nil
    }

    private func resume(at t: TimeInterval, reason: TransitionReason) {
        transition(to: resumeState, at: t, reason: reason)
        // Don't charge paused time against the stage timeout.
        stageStartTime = t
    }

    // MARK: - Active-state logic

    private func updateActive(_ input: GuidanceInput) {
        let t = input.timestamp
        guard let direction = currentDirection else { return }

        // Generous timeout — failure/retry only, NEVER automatic success.
        if let start = stageStartTime, t - start > config.stageTimeoutSeconds,
           state != .holdingNeutral {
            retryCount += 1
            transition(to: .returningToNeutral, at: t, reason: .stageTimeout)
            stageStartTime = t
            holdStartTime = nil
            neutralHoldStartTime = nil
            return
        }

        let directional = HeadDirectionProgress.evaluate(
            phase: direction,
            yawDegrees: input.yawDegrees,
            pitchDegrees: input.pitchDegrees,
            config: config)
        let center = HeadDirectionProgress.evaluate(
            phase: .center,
            yawDegrees: input.yawDegrees,
            pitchDegrees: input.pitchDegrees,
            config: config)

        switch state {
        case .instructingDirection:
            if directional.fraction >= config.movementStartFraction {
                transition(to: .movingTowardTarget, at: t, reason: .movementStarted)
            }

        case .movingTowardTarget:
            if directional.isOnTarget {
                holdStartTime = t
                transition(to: .holdingTargetPose, at: t, reason: .targetReached)
            }

        case .holdingTargetPose:
            if !directional.isOnTarget {
                holdStartTime = nil
                transition(to: .movingTowardTarget, at: t, reason: .holdBroken)
            } else if let start = holdStartTime, t - start >= config.targetHoldSeconds {
                completedDirections.insert(direction)
                holdStartTime = nil
                transition(to: .returningToNeutral, at: t, reason: .holdCompleted)
            }

        case .returningToNeutral:
            if center.isOnTarget {
                neutralHoldStartTime = t
                transition(to: .holdingNeutral, at: t, reason: .reachedNeutral)
            }

        case .holdingNeutral:
            if !center.isOnTarget {
                neutralHoldStartTime = nil
                transition(to: .returningToNeutral, at: t, reason: .leftNeutral)
            } else if let start = neutralHoldStartTime,
                      t - start >= config.neutralHoldSeconds {
                neutralHoldStartTime = nil
                advanceStage(at: t)
            }

        default:
            break
        }
    }

    /// Called only after a completed neutral hold. The FIRST neutral hold
    /// (before any direction) verifies the starting position; it advances into
    /// the first directional stage rather than past it.
    private func advanceStage(at t: TimeInterval) {
        if completedDirections.contains(Self.directionSequence[stageIndex]) {
            // Current stage's direction is done and the user re-centered.
            if stageIndex + 1 >= Self.directionSequence.count {
                transition(to: .complete, at: t, reason: .allStagesComplete)
                return
            }
            stageIndex += 1
        }
        stageStartTime = t
        transition(to: .instructingDirection, at: t, reason: .neutralHoldCompleted)
    }

    // MARK: - Transition recording

    private func transition(to newState: StateKind, at t: TimeInterval,
                            reason: TransitionReason) {
        record(from: state, to: newState, at: t, reason: reason)
        state = newState
    }

    private func record(from: StateKind, to: StateKind, at t: TimeInterval,
                        reason: TransitionReason) {
        let elapsed = t - (startTimestamp ?? t)
        transitions.append(StageTransition(
            sessionElapsedSeconds: elapsed,
            fromState: from.rawValue,
            toState: to.rawValue,
            stagePhase: (currentDirection ?? .complete).rawValue,
            reason: reason.rawValue))
    }

    // MARK: - Output

    private func output(input: GuidanceInput) -> GuidanceOutput {
        let t = input.timestamp
        let direction = currentDirection

        var holdProgress = 0.0
        if state == .holdingTargetPose, let start = holdStartTime,
           config.targetHoldSeconds > 0 {
            holdProgress = min(1, (t - start) / config.targetHoldSeconds)
        } else if state == .holdingNeutral, let start = neutralHoldStartTime,
                  config.neutralHoldSeconds > 0 {
            holdProgress = min(1, (t - start) / config.neutralHoldSeconds)
        }

        var approach = 0.0
        if let direction, state == .instructingDirection || state == .movingTowardTarget
            || state == .holdingTargetPose {
            approach = HeadDirectionProgress.evaluate(
                phase: direction,
                yawDegrees: input.yawDegrees,
                pitchDegrees: input.pitchDegrees,
                config: config).fraction
        }

        return GuidanceOutput(
            state: state,
            direction: direction,
            protocolPhase: protocolPhaseLabel,
            instruction: instruction(for: input),
            feedback: feedback(for: input),
            holdProgress: holdProgress,
            approachProgress: approach,
            stageIndex: stageIndex,
            stageCount: Self.directionSequence.count,
            completedDirections: completedDirections,
            isComplete: state == .complete,
            isPaused: isPausedState(state))
    }

    /// Phase label written onto recorded samples. Preserves the existing
    /// CSV/JSON vocabulary: direction names while working toward/holding a
    /// direction, "center" while returning/holding neutral or paused,
    /// "complete" at the end.
    private var protocolPhaseLabel: ProtocolPhase {
        switch state {
        case .instructingDirection, .movingTowardTarget, .holdingTargetPose:
            return currentDirection ?? .center
        case .returningToNeutral, .holdingNeutral:
            return .center
        case .pausedForTracking, .pausedForDistance, .pausedForPhoneMotion:
            // Label by the interrupted sub-state so a pause mid-direction
            // doesn't mislabel samples as "center".
            switch resumeState {
            case .instructingDirection, .movingTowardTarget, .holdingTargetPose:
                return currentDirection ?? .center
            default:
                return .center
            }
        case .complete:
            return .complete
        }
    }

    /// Short instruction, worded for display right next to the fixation dot.
    private func instruction(for input: GuidanceInput) -> String {
        switch state {
        case .instructingDirection, .movingTowardTarget:
            return currentDirection.map { "Slowly \($0.shortMovementDescription)" } ?? ""
        case .holdingTargetPose:
            return "Hold"
        case .returningToNeutral:
            return "Return to center"
        case .holdingNeutral:
            return "Hold center"
        case .pausedForTracking:
            return "Face not tracked"
        case .pausedForPhoneMotion:
            return "Phone moved — hold it still"
        case .pausedForDistance:
            let deviation = input.distanceDeviationMeters ?? 0
            if abs(deviation) > config.guidedDistanceExitBandMeters {
                return deviation > 0 ? "Move closer" : "Move farther"
            }
            // Paused for a lateral drift — the head-position boundary shows the
            // precise "Move left/right/up/down" cue, so keep this generic.
            return "Recenter your face"
        case .complete:
            return "Done"
        }
    }

    private func feedback(for input: GuidanceInput) -> Feedback? {
        guard state == .instructingDirection || state == .movingTowardTarget,
              let direction = currentDirection,
              let target = HeadDirectionTarget.target(for: direction),
              let yaw = input.yawDegrees, let pitch = input.pitchDegrees else { return nil }

        if let velocity = input.angularVelocityDegPerSec,
           velocity > config.guidedMaxAngularVelocityDegPerSec {
            return .tooFast
        }
        let achieved = target.achievedDegrees(yawDegrees: yaw, pitchDegrees: pitch)
        if achieved < -config.wrongDirectionThresholdDegrees {
            return .wrongDirection
        }
        let progress = HeadDirectionProgress.evaluate(
            phase: direction, yawDegrees: yaw, pitchDegrees: pitch, config: config)
        if progress.isOffAxis {
            return .offAxis
        }
        return nil
    }
}

extension ProtocolPhase {
    /// Movement phrasing used in guided instructions ("Slowly …").
    var shortMovementDescription: String {
        switch self {
        case .up: return "turn your head up"
        case .down: return "turn your head down"
        case .left: return "turn your head left"
        case .right: return "turn your head right"
        case .upperLeft: return "turn your head upper-left"
        case .upperRight: return "turn your head upper-right"
        case .lowerLeft: return "turn your head lower-left"
        case .lowerRight: return "turn your head lower-right"
        case .center: return "return to center"
        case .idle, .neutralCapture, .complete: return ""
        }
    }
}
