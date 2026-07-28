import Foundation

/// Pose-driven state machine for the continuous spiral sweep protocol.
///
/// The participant keeps their eyes on the fixed fixation dot and rotates
/// their head to follow a guide that traces a `SpiralSweepPath`. Because the
/// Aria eye camera is head-mounted, holding fixation while the head rotates
/// makes the eye counter-rotate through exactly the eye-in-head field the
/// gaze model needs — and the spiral visits that field at uniform areal
/// density instead of along eight radial lines.
///
/// State graph:
///
///     returningToNeutral ──reachedNeutral──▶ holdingNeutral
///     holdingNeutral ──leftNeutral──▶ returningToNeutral
///     holdingNeutral ──sweepStarted──▶ sweeping
///     sweeping ──sweepStalled──▶ sweepStalled
///     sweepStalled ──sweepResumed──▶ sweeping
///     sweeping ──sweepCompleted──▶ returningToNeutral (final)
///     holdingNeutral (final) ──allStagesComplete──▶ complete
///
/// plus the same tracking / distance / phone-motion pause states as the
/// eight-spoke protocol.
///
/// **The guide never runs away.** Progress advances only while the head is
/// within `sweepFollowToleranceDegrees` of the guide; otherwise the guide
/// waits (`sweepStalled`). So elapsed time is never credited as coverage, and
/// every recorded pose genuinely lies near the intended path. The corollary
/// is that a participant who stops following simply never finishes — there is
/// deliberately no timeout that would auto-complete a sweep. Stopping early is
/// safe: `sweepProgress` is recorded per sample, so a partial sweep is still
/// usable data.
final class SpiralSweepController: ProtocolControlling {

    private let config: MeasurementConfig
    private let path: SpiralSweepPath

    // MARK: - State

    private(set) var state: GuidanceStateKind = .returningToNeutral
    private(set) var transitions: [ProtocolTransition] = []
    /// Seconds of *following* accumulated — not wall-clock elapsed.
    private(set) var sweepElapsed: TimeInterval = 0
    /// True once the spiral has been traversed end to end.
    private(set) var sweepFinished = false

    private var resumeState: GuidanceStateKind = .returningToNeutral
    private var startTimestamp: TimeInterval?
    private var lastUpdateTimestamp: TimeInterval?
    private var neutralHoldStartTime: TimeInterval?

    // Distance hysteresis bookkeeping (mirrors GuidedMovementController).
    private var distanceOutsideSince: TimeInterval?
    private var distanceInsideSince: TimeInterval?

    init(config: MeasurementConfig) {
        self.config = config
        self.path = SpiralSweepPath(config: config)
    }

    /// 0…1 along the spiral.
    var progress: Double {
        guard config.sweepDurationSeconds > 0 else { return 1 }
        return min(1, sweepElapsed / config.sweepDurationSeconds)
    }

    private var currentTarget: SpiralSweepPath.Target {
        path.target(atProgress: progress)
    }

    // MARK: - Update

    func update(_ input: ProtocolGuidanceInput) -> ProtocolGuidanceOutput {
        let t = input.timestamp
        if startTimestamp == nil {
            startTimestamp = t
            record(from: state, to: state, at: t, reason: .recordingStarted)
        }

        // A long gap between updates (backgrounding, user pause) must not be
        // credited to the neutral hold or to sweep progress.
        var dt: TimeInterval = 0
        if let last = lastUpdateTimestamp {
            let gap = t - last
            if gap > config.updateGapResetSeconds {
                neutralHoldStartTime = neutralHoldStartTime.map { $0 + gap }
                distanceOutsideSince = nil
                distanceInsideSince = nil
            } else {
                dt = max(0, gap)
            }
        }
        lastUpdateTimestamp = t

        guard state != .complete else { return output(input: input) }

        updatePauses(input)

        if !isPausedState(state) {
            updateActive(input, dt: dt)
        }

        return output(input: input)
    }

    // MARK: - Pause handling

    private func isPausedState(_ s: GuidanceStateKind) -> Bool {
        s == .pausedForTracking || s == .pausedForDistance || s == .pausedForPhoneMotion
    }

    /// Highest-priority failure wins: tracking > phone motion > distance.
    /// Identical policy to the eight-spoke protocol so the two modes pause on
    /// exactly the same conditions and remain comparable.
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
            // Demote holds so paused time never counts as held time. A paused
            // sweep resumes into `sweeping`, which immediately re-stalls if
            // the head is no longer near the guide.
            switch state {
            case .holdingNeutral: resumeState = .returningToNeutral
            case .sweepStalled: resumeState = .sweeping
            default: resumeState = state
            }
        }
        transition(to: pauseState, at: t, reason: reason)
        neutralHoldStartTime = nil
    }

    private func resume(at t: TimeInterval, reason: GuidanceTransitionReason) {
        transition(to: resumeState, at: t, reason: reason)
    }

    // MARK: - Active-state logic

    private func updateActive(_ input: ProtocolGuidanceInput, dt: TimeInterval) {
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
                if sweepFinished {
                    transition(to: .complete, at: t, reason: .allStagesComplete)
                } else {
                    transition(to: .sweeping, at: t, reason: .sweepStarted)
                }
            }

        case .sweeping:
            guard let error = trackingError(input) else { return }
            if error > config.sweepFollowToleranceDegrees {
                transition(to: .sweepStalled, at: t, reason: .sweepStalled)
                return
            }
            sweepElapsed += dt
            if progress >= 1 {
                sweepFinished = true
                transition(to: .returningToNeutral, at: t, reason: .sweepCompleted)
            }

        case .sweepStalled:
            guard let error = trackingError(input) else { return }
            // Hysteresis: require a tighter error to resume than to stall, so
            // a head hovering at the boundary doesn't chatter.
            if error <= config.sweepFollowResumeDegrees {
                transition(to: .sweeping, at: t, reason: .sweepResumed)
            }

        default:
            break
        }
    }

    /// Angular distance from the measured pose to the guide, nil when the
    /// pose is unavailable.
    private func trackingError(_ input: ProtocolGuidanceInput) -> Double? {
        guard let yaw = input.yawDegrees, let pitch = input.pitchDegrees,
              yaw.isFinite, pitch.isFinite else { return nil }
        return SpiralSweepPath.trackingError(yawDegrees: yaw, pitchDegrees: pitch,
                                             target: currentTarget)
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

        // The guide outline is shown only while the sweep is actually running
        // (or paused mid-sweep), never during the settle or final return —
        // those phases ask for neutral, and a visible off-neutral outline
        // would contradict the instruction.
        var sweep: SweepGuidanceState?
        if showsSweepGuide {
            let target = currentTarget
            sweep = SweepGuidanceState(
                progress: progress,
                targetYawDegrees: target.yawDegrees,
                targetPitchDegrees: target.pitchDegrees,
                trackingErrorDegrees: trackingError(input),
                isStalled: state == .sweepStalled)
        }

        return ProtocolGuidanceOutput(
            state: state,
            direction: nil,
            protocolPhase: protocolPhaseLabel,
            instruction: instruction(for: input),
            feedback: feedback(for: input),
            holdProgress: holdProgress,
            approachProgress: progress,
            stageIndex: 0,
            stageCount: 1,
            completedDirections: [],
            isComplete: state == .complete,
            isPaused: isPausedState(state),
            sweep: sweep)
    }

    private var showsSweepGuide: Bool {
        switch state {
        case .sweeping, .sweepStalled:
            return true
        case .pausedForTracking, .pausedForDistance, .pausedForPhoneMotion:
            return resumeState == .sweeping || resumeState == .sweepStalled
        default:
            return false
        }
    }

    /// Phase label written onto recorded samples: `sweep` while following the
    /// spiral, `center` while settling or returning, `complete` at the end.
    private var protocolPhaseLabel: ProtocolPhase {
        switch state {
        case .sweeping, .sweepStalled:
            return .sweep
        case .returningToNeutral, .holdingNeutral:
            return .center
        case .pausedForTracking, .pausedForDistance, .pausedForPhoneMotion:
            return (resumeState == .sweeping || resumeState == .sweepStalled)
                ? .sweep : .center
        case .complete:
            return .complete
        default:
            return .center
        }
    }

    private func instruction(for input: ProtocolGuidanceInput) -> String {
        switch state {
        case .returningToNeutral:
            return sweepFinished ? "Return to center" : "Center your head to begin"
        case .holdingNeutral:
            return "Hold center"
        case .sweeping:
            return "Follow the outline — eyes on the dot"
        case .sweepStalled:
            return "Catch up to the outline"
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
        guard state == .sweeping || state == .sweepStalled else { return nil }
        if let velocity = input.angularVelocityDegPerSec,
           velocity > config.guidedMaxAngularVelocityDegPerSec {
            return .tooFast
        }
        if state == .sweepStalled { return .behindGuide }
        return nil
    }
}
