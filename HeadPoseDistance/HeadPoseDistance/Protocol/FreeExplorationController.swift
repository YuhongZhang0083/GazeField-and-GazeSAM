import Foundation

/// Pose-driven state machine for the free-exploration protocol.
///
/// The participant keeps their eyes on the fixed fixation dot and moves their
/// head freely — in practice, slow widening circles, as if drawing with the
/// nose around the dot. There is **no target to match and nothing to follow**:
/// a coverage grid shows which parts of the (yaw, pitch) field still need
/// samples, and the session ends when enough of the field is covered.
///
/// This replaced a guided spiral. The spiral produced uniform areal density
/// *if followed accurately*, but asking someone to match the orientation of a
/// translucent 3D head — in peripheral vision, while holding fixation — was an
/// interface people could not read. Measuring coverage directly is easier to
/// perform and a stronger guarantee: every required cell must hold at least
/// `coverageSamplesPerCell` usable samples, rather than density being inferred
/// from how well a path was tracked.
///
/// State graph:
///
///     returningToNeutral ──reachedNeutral──▶ holdingNeutral
///     holdingNeutral ──leftNeutral──▶ returningToNeutral
///     holdingNeutral ──explorationStarted──▶ exploring
///     exploring ──coverageComplete──▶ returningToNeutral (final)
///     holdingNeutral (final) ──allStagesComplete──▶ complete
///
/// plus the same tracking / distance / phone-motion pause states as the other
/// protocols. Coverage accrues only while `exploring`, unpaused, and moving
/// slowly enough to be usable — so elapsed time is never credited as coverage,
/// and there is deliberately no timeout that could finish a session early.
/// Stopping early is safe: per-sample coverage is exported.
final class FreeExplorationController: ProtocolControlling {

    private let config: MeasurementConfig

    // MARK: - State

    private(set) var state: GuidanceStateKind = .returningToNeutral
    private(set) var transitions: [ProtocolTransition] = []
    private(set) var grid: CoverageGrid
    private(set) var coverageComplete = false

    private var resumeState: GuidanceStateKind = .returningToNeutral
    private var startTimestamp: TimeInterval?
    private var lastUpdateTimestamp: TimeInterval?
    private var neutralHoldStartTime: TimeInterval?
    private var firstExploreStartTime: TimeInterval?
    /// Set for the single frame on which a required cell filled up, so the view
    /// model can fire one haptic tick.
    private var completedCellThisFrame = false

    // Distance hysteresis bookkeeping (mirrors the other controllers).
    private var distanceOutsideSince: TimeInterval?
    private var distanceInsideSince: TimeInterval?

    init(config: MeasurementConfig) {
        self.config = config
        self.grid = CoverageGrid(config: config)
    }

    // MARK: - Update

    func update(_ input: ProtocolGuidanceInput) -> ProtocolGuidanceOutput {
        let t = input.timestamp
        completedCellThisFrame = false

        if startTimestamp == nil {
            startTimestamp = t
            record(from: state, to: state, at: t, reason: .recordingStarted)
        }

        // A long gap between updates (backgrounding, user pause) must not be
        // credited to the neutral hold.
        if let last = lastUpdateTimestamp, t - last > config.updateGapResetSeconds {
            let gap = t - last
            neutralHoldStartTime = neutralHoldStartTime.map { $0 + gap }
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

    private func isPausedState(_ s: GuidanceStateKind) -> Bool {
        s == .pausedForTracking || s == .pausedForDistance || s == .pausedForPhoneMotion
    }

    /// Highest-priority failure wins: tracking > phone motion > distance.
    /// Identical policy to the other protocols so all modes pause on exactly
    /// the same conditions and stay comparable.
    private func updatePauses(_ input: ProtocolGuidanceInput) {
        let t = input.timestamp

        if !input.faceTracked {
            if state != .pausedForTracking {
                pause(to: .pausedForTracking, at: t, reason: .trackingLost)
            }
            return
        }
        if state == .pausedForTracking {
            resume(at: t, reason: .trackingRecovered)
        }

        if input.phoneStability == .excessive {
            if state != .pausedForPhoneMotion {
                pause(to: .pausedForPhoneMotion, at: t, reason: .phoneMotionExcessive)
            }
            return
        }
        if state == .pausedForPhoneMotion {
            resume(at: t, reason: .phoneMotionEnded)
        }

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

    private func pause(to pauseState: GuidanceStateKind, at t: TimeInterval,
                       reason: GuidanceTransitionReason) {
        if !isPausedState(state) {
            // Demote the neutral hold so paused time never counts as held time.
            resumeState = state == .holdingNeutral ? .returningToNeutral : state
        }
        transition(to: pauseState, at: t, reason: reason)
        neutralHoldStartTime = nil
    }

    private func resume(at t: TimeInterval, reason: GuidanceTransitionReason) {
        transition(to: resumeState, at: t, reason: reason)
    }

    // MARK: - Active-state logic

    private func updateActive(_ input: ProtocolGuidanceInput) {
        let t = input.timestamp

        let center = HeadDirectionProgress.evaluate(
            phase: .center,
            yawDegrees: input.yawDegrees,
            pitchDegrees: input.pitchDegrees,
            config: config)

        switch state {
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
                if coverageComplete {
                    transition(to: .complete, at: t, reason: .allStagesComplete)
                } else {
                    if firstExploreStartTime == nil { firstExploreStartTime = t }
                    transition(to: .exploring, at: t, reason: .explorationStarted)
                }
            }

        case .exploring:
            accumulateCoverage(input)
            if grid.coveredFraction >= config.coverageCompletionFraction {
                coverageComplete = true
                transition(to: .returningToNeutral, at: t, reason: .coverageComplete)
            }

        default:
            break
        }
    }

    /// Adds the current pose to the grid, but only when it is data the gaze
    /// field can actually use. Reaching this point already means the face is
    /// tracked, the phone is still, and distance/lateral position are inside
    /// their bands (otherwise the protocol would be paused); the remaining gate
    /// is head speed, which doubles as the "move slowly" requirement.
    private func accumulateCoverage(_ input: ProtocolGuidanceInput) {
        guard let yaw = input.yawDegrees, let pitch = input.pitchDegrees else { return }
        if let velocity = input.angularVelocityDegPerSec,
           velocity > config.guidedMaxAngularVelocityDegPerSec {
            return
        }
        completedCellThisFrame = grid.add(yawDegrees: yaw, pitchDegrees: pitch)
    }

    // MARK: - Transition recording

    private func transition(to newState: GuidanceStateKind, at t: TimeInterval,
                            reason: GuidanceTransitionReason) {
        record(from: state, to: newState, at: t, reason: reason)
        state = newState
    }

    private func record(from: GuidanceStateKind, to: GuidanceStateKind,
                        at t: TimeInterval, reason: GuidanceTransitionReason) {
        let elapsed = t - (startTimestamp ?? t)
        transitions.append(ProtocolTransition(
            sessionElapsedSeconds: elapsed,
            fromState: from.rawValue,
            toState: to.rawValue,
            stagePhase: protocolPhaseLabel.rawValue,
            reason: reason.rawValue))
    }

    // MARK: - Output

    private func output(input: ProtocolGuidanceInput) -> ProtocolGuidanceOutput {
        let t = input.timestamp

        var holdProgress = 0.0
        if state == .holdingNeutral, let start = neutralHoldStartTime,
           config.neutralHoldSeconds > 0 {
            holdProgress = min(1, (t - start) / config.neutralHoldSeconds)
        }

        var cell: (column: Int, row: Int)?
        if showsCoverage, let yaw = input.yawDegrees, let pitch = input.pitchDegrees {
            cell = grid.cell(yawDegrees: yaw, pitchDegrees: pitch)
        }

        let coverage = ExplorationGuidanceState(
            columns: grid.columns,
            rows: grid.rows,
            cellFill: grid.fillFractions,
            cellRequired: grid.requiredFlags,
            coveredCells: grid.coveredRequiredCellCount,
            requiredCells: grid.requiredCellCount,
            coveredFraction: grid.coveredFraction,
            currentColumn: cell?.column,
            currentRow: cell?.row,
            completedCellThisFrame: completedCellThisFrame)

        return ProtocolGuidanceOutput(
            state: state,
            direction: nil,
            protocolPhase: protocolPhaseLabel,
            instruction: instruction(for: input),
            feedback: feedback(for: input),
            holdProgress: holdProgress,
            approachProgress: grid.coveredFraction,
            stageIndex: 0,
            stageCount: 1,
            completedDirections: [],
            isComplete: state == .complete,
            isPaused: isPausedState(state),
            coverage: coverage)
    }

    private var showsCoverage: Bool {
        switch state {
        case .exploring:
            return true
        case .pausedForTracking, .pausedForDistance, .pausedForPhoneMotion:
            return resumeState == .exploring
        default:
            return false
        }
    }

    /// Phase label written onto recorded samples.
    private var protocolPhaseLabel: ProtocolPhase {
        switch state {
        case .exploring:
            return .explore
        case .returningToNeutral, .holdingNeutral:
            return .center
        case .pausedForTracking, .pausedForDistance, .pausedForPhoneMotion:
            return resumeState == .exploring ? .explore : .center
        case .complete:
            return .complete
        default:
            return .center
        }
    }

    private func instruction(for input: ProtocolGuidanceInput) -> String {
        switch state {
        case .returningToNeutral:
            return coverageComplete ? "Return to center" : "Face straight ahead to begin"
        case .holdingNeutral:
            return "Hold still"
        case .exploring:
            // The caption sits below the fixation dot, so reading it breaks
            // fixation. It orients the participant and then gets out of the
            // way — the grid at the bottom carries the state from then on.
            if let start = firstExploreStartTime,
               input.timestamp - start > config.explorationInstructionSeconds {
                return ""
            }
            return "Circle your nose around the dot, slowly"
        case .pausedForTracking:
            return "Face not tracked"
        case .pausedForPhoneMotion:
            return "Phone moved — hold it still"
        case .pausedForDistance:
            let deviation = input.distanceDeviationMeters ?? 0
            if abs(deviation) > config.guidedDistanceExitBandMeters {
                return deviation > 0 ? "Move closer" : "Move farther"
            }
            return "Recenter your face"
        case .complete:
            return "Done"
        default:
            return ""
        }
    }

    private func feedback(for input: ProtocolGuidanceInput) -> GuidanceFeedback? {
        guard state == .exploring else { return nil }
        if let velocity = input.angularVelocityDegPerSec,
           velocity > config.guidedMaxAngularVelocityDegPerSec {
            // Not cosmetic: samples above this speed are not counted, so the
            // participant needs to know why coverage stopped growing.
            return .tooFast
        }
        return nil
    }
}
