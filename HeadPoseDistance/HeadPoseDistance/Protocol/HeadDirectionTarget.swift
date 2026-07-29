import Foundation

/// Target head orientation for each protocol phase, expressed in the
/// **user-facing** relative-Euler convention produced by `HeadPoseConvention`:
///
/// - `yaw`   > 0  → head turned to the participant's RIGHT
/// - `pitch` > 0  → head rotated UP
///
/// Both conventions are documented assumptions pending physical-device
/// verification (see README). If device testing shows a flipped axis, correct
/// it in `HeadPoseConvention` — this file derives everything from that
/// convention and needs no change.
///
/// Achievement is judged from the ACTUAL measured angles, never from elapsed
/// time: the UI only shows a direction as reached when the head really got
/// there, which keeps the on-screen feedback consistent with the recorded data.
struct HeadDirectionTarget: Equatable {

    /// Unit vector in (yaw, pitch) degrees-space, or `.zero` for the center
    /// phase, which is a "return to neutral" target rather than a direction.
    let yawUnit: Double
    let pitchUnit: Double

    var isCenter: Bool { yawUnit == 0 && pitchUnit == 0 }

    static let center = HeadDirectionTarget(yawUnit: 0, pitchUnit: 0)

    private static let diagonal = 1.0 / 2.0.squareRoot()

    /// Target for a phase, or nil for phases with no head-direction goal
    /// (idle, neutral capture, complete).
    static func target(for phase: ProtocolPhase) -> HeadDirectionTarget? {
        switch phase {
        case .center:      return .center
        case .up:          return HeadDirectionTarget(yawUnit: 0, pitchUnit: 1)
        case .down:        return HeadDirectionTarget(yawUnit: 0, pitchUnit: -1)
        case .left:        return HeadDirectionTarget(yawUnit: -1, pitchUnit: 0)
        case .right:       return HeadDirectionTarget(yawUnit: 1, pitchUnit: 0)
        case .upperLeft:   return HeadDirectionTarget(yawUnit: -diagonal, pitchUnit: diagonal)
        case .upperRight:  return HeadDirectionTarget(yawUnit: diagonal, pitchUnit: diagonal)
        case .lowerLeft:   return HeadDirectionTarget(yawUnit: -diagonal, pitchUnit: -diagonal)
        case .lowerRight:  return HeadDirectionTarget(yawUnit: diagonal, pitchUnit: -diagonal)
        // Free exploration has no target at all — coverage is measured, not
        // aimed at.
        case .explore: return nil
        case .idle, .neutralCapture, .complete: return nil
        }
    }

    /// Signed rotation achieved toward this target, in degrees: the projection
    /// of the measured (yaw, pitch) onto the target direction. Negative means
    /// the head turned the opposite way.
    func achievedDegrees(yawDegrees: Double, pitchDegrees: Double) -> Double {
        yawDegrees * yawUnit + pitchDegrees * pitchUnit
    }

    /// Degrees of rotation perpendicular to the target direction — how far the
    /// movement strayed off-axis (e.g. yaw drift while being asked to look up).
    func offAxisDegrees(yawDegrees: Double, pitchDegrees: Double) -> Double {
        abs(yawDegrees * -pitchUnit + pitchDegrees * yawUnit)
    }
}

/// Live evaluation of how well the head matches the current phase target.
struct HeadDirectionProgress: Equatable {
    /// 0…1 fraction of the required angle achieved along the target axis.
    var fraction: Double = 0
    /// Signed degrees achieved along the target axis (or, for the center
    /// phase, the total deviation from neutral).
    var achievedDegrees: Double = 0
    /// Required angle for this phase, in degrees.
    var requiredDegrees: Double = 0
    /// True once the head is within the phase's acceptance criteria.
    var isOnTarget = false
    /// True when the movement has drifted noticeably off the requested axis.
    var isOffAxis = false

    static let none = HeadDirectionProgress()

    /// Evaluates the measured relative angles against the phase target.
    ///
    /// - For directional phases: on target once the achieved angle reaches
    ///   `targetAngleDegrees` **and** off-axis drift stays within
    ///   `maxOffAxisDegrees`.
    /// - For the center phase: on target once total deviation from neutral
    ///   falls below `centerToleranceDegrees`; `fraction` counts *down* toward
    ///   centered so the progress bar still fills as the user succeeds.
    static func evaluate(phase: ProtocolPhase,
                         yawDegrees: Double?,
                         pitchDegrees: Double?,
                         config: MeasurementConfig) -> HeadDirectionProgress {
        guard let target = HeadDirectionTarget.target(for: phase),
              let yaw = yawDegrees, let pitch = pitchDegrees,
              yaw.isFinite, pitch.isFinite else { return .none }

        if target.isCenter {
            let deviation = (yaw * yaw + pitch * pitch).squareRoot()
            let tolerance = max(config.centerToleranceDegrees, 0.001)
            return HeadDirectionProgress(
                fraction: max(0, min(1, 1 - deviation / (tolerance * 3))),
                achievedDegrees: deviation,
                requiredDegrees: tolerance,
                isOnTarget: deviation <= tolerance,
                isOffAxis: false)
        }

        let required = max(config.targetAngleDegrees, 0.001)
        let achieved = target.achievedDegrees(yawDegrees: yaw, pitchDegrees: pitch)
        let offAxis = target.offAxisDegrees(yawDegrees: yaw, pitchDegrees: pitch)
        let offAxisExceeded = offAxis > config.maxOffAxisDegrees
        return HeadDirectionProgress(
            fraction: max(0, min(1, achieved / required)),
            achievedDegrees: achieved,
            requiredDegrees: required,
            isOnTarget: achieved >= required && !offAxisExceeded,
            // Only nag about off-axis drift once the user has actually started
            // moving, so small jitter at neutral doesn't flash a warning.
            isOffAxis: offAxisExceeded && achieved > required * 0.25)
    }
}
