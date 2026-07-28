import Foundation

/// The head-movement path for the spiral sweep protocol, in neutral-relative
/// (yaw, pitch) degrees.
///
/// ## Why a spiral, and why *this* parameterization
///
/// The eight-spoke protocol samples eight radial lines and piles ~40% of its
/// samples at neutral, leaving the wedges between spokes empty. The heatmap
/// stage (`adaptive_kernel_convolution_heatmaps.py`) masks to the convex hull
/// of the samples, so those empty wedges get filled by kernel extrapolation
/// and the output *looks* complete where nothing was measured.
///
/// A spiral fixes the coverage, but only if it is traversed correctly. Two
/// choices matter:
///
/// 1. **Archimedean (r ∝ θ), not logarithmic** — successive turns are evenly
///    spaced in radius, so ring spacing is uniform: `(1 - inner) / turns`.
/// 2. **Constant tangential speed, not constant angular rate.** A constant
///    angular rate dwells near the centre and would reproduce exactly the
///    centre pile-up we are trying to remove. Constant tangential speed gives
///    uniform samples per unit *area*.
///
/// Achieving (2) is what `target(atProgress:)` does. With normalized radius
/// `ρ` and progress `u`:
///
///     ρ(u) = √(ρ₀² + (1 − ρ₀²)·u)
///
/// so `ρ²` — and therefore the enclosed area — grows linearly with `u`. Since
/// samples arrive at a fixed rate (60 Hz), equal time means equal area means
/// **uniform areal sample density**. The tangential speed that falls out is
/// constant to within ~2% over the whole path (see `speedUniformityRatio`).
///
/// The elliptical amplitudes (`yawAmplitudeDegrees` ≠ `pitchAmplitudeDegrees`)
/// are a linear map of the unit disk, which preserves uniform density while
/// matching the smaller comfortable vertical range of eye-in-head rotation.
struct SpiralSweepPath: Equatable {

    /// Half-range of the sweep along yaw (degrees).
    var yawAmplitudeDegrees: Double
    /// Half-range along pitch (degrees). Normally smaller than yaw.
    var pitchAmplitudeDegrees: Double
    /// Number of complete turns between the inner and outer radius. Ring
    /// spacing is `(1 - innerRadiusFraction) / turns` of full amplitude.
    var turns: Double
    /// Where the spiral starts, as a fraction of full amplitude. A small
    /// non-zero value skips the degenerate tight loop at the exact centre,
    /// which no head can follow comfortably. Neutral itself is already
    /// well sampled by the settle and return phases.
    var innerRadiusFraction: Double

    init(yawAmplitudeDegrees: Double,
         pitchAmplitudeDegrees: Double,
         turns: Double,
         innerRadiusFraction: Double) {
        self.yawAmplitudeDegrees = max(0, yawAmplitudeDegrees)
        self.pitchAmplitudeDegrees = max(0, pitchAmplitudeDegrees)
        self.turns = max(0.5, turns)
        self.innerRadiusFraction = min(max(innerRadiusFraction, 0), 0.9)
    }

    init(config: MeasurementConfig) {
        self.init(yawAmplitudeDegrees: config.sweepYawAmplitudeDegrees,
                  pitchAmplitudeDegrees: config.sweepPitchAmplitudeDegrees,
                  turns: config.sweepTurns,
                  innerRadiusFraction: config.sweepInnerRadiusFraction)
    }

    struct Target: Equatable {
        var yawDegrees: Double
        var pitchDegrees: Double
    }

    /// Guide position at `progress` ∈ 0…1. Out-of-range values are clamped,
    /// so a caller never has to guard the ends.
    func target(atProgress progress: Double) -> Target {
        guard progress.isFinite else { return Target(yawDegrees: 0, pitchDegrees: 0) }
        let u = min(max(progress, 0), 1)
        let r0 = innerRadiusFraction

        // Equal area per unit progress.
        let rho = (r0 * r0 + (1 - r0 * r0) * u).squareRoot()
        // Archimedean: angle advances linearly with radius, so ring spacing
        // in radius is constant.
        let theta = 2 * .pi * turns * (rho - r0) / max(1 - r0, 1e-9)

        return Target(yawDegrees: yawAmplitudeDegrees * rho * cos(theta),
                      pitchDegrees: pitchAmplitudeDegrees * rho * sin(theta))
    }

    /// Radial gap between successive turns, as a fraction of full amplitude.
    /// Keep the resulting degree spacing at or below the heatmap's
    /// `--sigma-min` (3° by default) so smoothing interpolates between
    /// measured rings instead of across unmeasured gaps.
    var ringSpacingFraction: Double {
        (1 - innerRadiusFraction) / turns
    }

    /// Ring spacing along the yaw axis, in degrees — the axis with the larger
    /// amplitude, hence the worst-case (widest) gap.
    var ringSpacingDegrees: Double {
        yawAmplitudeDegrees * ringSpacingFraction
    }

    /// Total path length in degrees, integrated numerically.
    func pathLengthDegrees(samples: Int = 4000) -> Double {
        segmentLengths(samples: samples).reduce(0, +)
    }

    /// Mean tangential speed for a sweep of `duration` seconds.
    func meanSpeedDegreesPerSecond(duration: Double) -> Double {
        guard duration > 0 else { return .infinity }
        return pathLengthDegrees() / duration
    }

    /// Peak tangential speed for a sweep of `duration` seconds. Used to keep
    /// the guide below the protocol's too-fast threshold and below the speed
    /// at which the eye camera starts to motion-blur.
    func peakSpeedDegreesPerSecond(duration: Double, samples: Int = 4000) -> Double {
        guard duration > 0, samples > 1 else { return .infinity }
        let dt = duration / Double(samples)
        return (segmentLengths(samples: samples).max() ?? 0) / dt
    }

    /// Ratio of peak to mean tangential speed **in degree space**.
    ///
    /// This is NOT ~1.0 for the shipped configuration, and that is expected:
    /// the elliptical amplitudes stretch yaw more than pitch, so the guide
    /// covers degrees faster along yaw than along pitch, by up to
    /// `yawAmplitude / pitchAmplitude`. Uniform areal density is unaffected —
    /// a linear map scales every area by the same factor `A·B`, so uniform
    /// density in the unit disk stays uniform in the ellipse. Use this ratio
    /// for the speed budget; use `normalizedSpeedUniformityRatio` to check the
    /// underlying constant-speed property.
    func speedUniformityRatio(samples: Int = 4000) -> Double {
        ratio(of: segmentLengths(samples: samples, normalized: false))
    }

    /// Peak-to-mean speed on the normalized (circular) path, with the
    /// elliptical stretch divided out. This is the property that makes areal
    /// density uniform, and it lands within a couple of percent of 1.0.
    func normalizedSpeedUniformityRatio(samples: Int = 4000) -> Double {
        ratio(of: segmentLengths(samples: samples, normalized: true))
    }

    private func ratio(of lengths: [Double]) -> Double {
        guard let peak = lengths.max(), !lengths.isEmpty else { return .infinity }
        let mean = lengths.reduce(0, +) / Double(lengths.count)
        guard mean > 0 else { return .infinity }
        return peak / mean
    }

    /// Per-step chord lengths along the path, in degrees — or in units of
    /// amplitude when `normalized`, which removes the elliptical stretch.
    private func segmentLengths(samples: Int, normalized: Bool = false) -> [Double] {
        let n = max(2, samples)
        let yawScale = normalized ? 1 / max(yawAmplitudeDegrees, 1e-9) : 1
        let pitchScale = normalized ? 1 / max(pitchAmplitudeDegrees, 1e-9) : 1
        var lengths: [Double] = []
        lengths.reserveCapacity(n)
        var previous = target(atProgress: 0)
        for i in 1...n {
            let current = target(atProgress: Double(i) / Double(n))
            let dy = (current.yawDegrees - previous.yawDegrees) * yawScale
            let dp = (current.pitchDegrees - previous.pitchDegrees) * pitchScale
            lengths.append((dy * dy + dp * dp).squareRoot())
            previous = current
        }
        return lengths
    }

    /// Angular distance from a measured pose to a guide target, in degrees.
    /// Small-angle planar metric — consistent with how the eight-spoke
    /// protocol measures its own on-axis/off-axis errors.
    static func trackingError(yawDegrees: Double, pitchDegrees: Double,
                              target: Target) -> Double {
        let dy = yawDegrees - target.yawDegrees
        let dp = pitchDegrees - target.pitchDegrees
        return (dy * dy + dp * dp).squareRoot()
    }
}
