import SwiftUI

/// Screens 3–5: live measurement, neutral capture, and guided head-movement
/// recording.
///
/// Design rules (research protocol):
/// - Exactly ONE fixation target: the fixed red dot at the exact center of
///   the usable screen. It never moves, is never obscured, and no other
///   element may look like a target.
/// - There is **no live camera video** anywhere in this workflow (debug view
///   only). Head feedback comes from a generic virtual 3D head driven by
///   tracking data.
/// - All movement guidance sits immediately AROUND the dot (arrow + short
///   text + hold ring) so the participant never has to look away to read it.
/// - Stage progression is pose-driven (GuidedMovementController); this view
///   only renders the controller's output — no protocol logic lives here.
struct MeasurementView: View {
    @EnvironmentObject private var viewModel: MeasurementViewModel

    var body: some View {
        GeometryReader { geometry in
            let center = CGPoint(x: geometry.size.width / 2,
                                 y: geometry.size.height / 2)
            ZStack {
                Color.black.ignoresSafeArea()

                // Guidance is drawn around — never over — the dot.
                CenterGuidanceOverlay(snapshot: viewModel.snapshot)
                    .position(center)

                // The single fixed fixation target, topmost at the center.
                // Its position depends only on screen geometry, never on
                // instruction or guidance state.
                CenterDotView(diameter: viewModel.config.dotDiameterPoints)
                    .position(center)

                VStack(spacing: 0) {
                    statusHeader
                    topPanel
                    Spacer(minLength: 0)
                    if showsReadouts {
                        measurementPanel
                    }
                    bottomBar
                }
            }
            .onAppear {
                let frame = geometry.frame(in: .global)
                viewModel.reportScreenGeometry(
                    dotCenterGlobal: CGPoint(x: frame.midX, y: frame.midY),
                    screenSize: geometry.size,
                    scale: UITraitCollection.current.displayScale)
            }
        }
        .sheet(isPresented: $viewModel.showDebugView) {
            DebugView()
        }
        .sheet(isPresented: $viewModel.showCalibrationSheet) {
            CalibrationSheet()
        }
        .alert("Neutral Capture Failed",
               isPresented: Binding(
                get: { viewModel.neutralCaptureMessage != nil },
                set: { if !$0 { viewModel.neutralCaptureMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.neutralCaptureMessage ?? "")
        }
    }

    /// The dense numeric panel is a setup aid; it disappears during recording
    /// so the screen stays quiet around the fixation dot.
    private var showsReadouts: Bool {
        switch viewModel.snapshot.stage {
        case .recording, .capturingNeutral: return false
        default: return true
        }
    }

    // MARK: - Status header

    private var statusHeader: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                statusChip(text: viewModel.snapshot.faceTracked ? "Face Tracked" : "No Face",
                           color: viewModel.snapshot.faceTracked ? .green : .red)
                statusChip(text: viewModel.snapshot.phoneStability.label,
                           color: phoneStabilityColor)
                statusChip(text: stageLabel, color: .blue)
                Spacer()
                Button {
                    viewModel.showCalibrationSheet = true
                } label: {
                    Image(systemName: "ruler")
                }
                Button {
                    viewModel.showDebugView = true
                } label: {
                    Image(systemName: "wrench.and.screwdriver")
                }
            }
            .font(.caption)

            if viewModel.snapshot.interrupted {
                Text("Session interrupted — samples are being rejected")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let error = viewModel.snapshot.sessionErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }

    private var phoneStabilityColor: Color {
        switch viewModel.snapshot.phoneStability {
        case .stable: return .green
        case .minor: return .yellow
        case .excessive: return .red
        case .unknown: return .gray
        }
    }

    private var stageLabel: String {
        switch viewModel.snapshot.stage {
        case .preview: return "Live"
        case .capturingNeutral: return "Neutral Capture"
        case .neutralReady: return "Ready"
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .finished: return "Finished"
        }
    }

    private func statusChip(text: String, color: Color) -> some View {
        Text(text)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.22)))
            .foregroundStyle(color)
    }

    // MARK: - Top panel: virtual head + alignment boundary

    private var topPanel: some View {
        AlignmentBoundaryPanel(snapshot: viewModel.snapshot,
                               dimmed: viewModel.snapshot.stage == .recording)
            .padding(.top, 2)
    }

    // MARK: - Measurement panel (setup aid)

    private var measurementPanel: some View {
        VStack(spacing: 10) {
            HStack(spacing: 18) {
                angleReadout(label: "Yaw", value: viewModel.snapshot.relativeEuler?.yawDegrees)
                angleReadout(label: "Pitch", value: viewModel.snapshot.relativeEuler?.pitchDegrees)
                angleReadout(label: "Roll", value: viewModel.snapshot.relativeEuler?.rollDegrees)
            }
            .padding(.vertical, 4)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                distanceRow("Head reference distance", viewModel.snapshot.headReferenceDistanceMeters)
                distanceRow("Forward depth", viewModel.snapshot.forwardDepthMeters)
                distanceRow(surfaceLabel, viewModel.snapshot.trueDepthSurfaceRawMeters)
                distanceRow("↳ filtered (median→EMA)", viewModel.snapshot.trueDepthSurfaceEMAFilteredMeters)
                distanceRow(screenDistanceLabel, viewModel.snapshot.estimatedScreenToFaceMeters)
                distanceRow("Baseline distance", viewModel.snapshot.baselineDistanceMeters)
                distanceRow("Deviation from baseline", viewModel.snapshot.distanceDeviationMeters,
                            signed: true,
                            highlight: viewModel.snapshot.distanceWarning)
            }
            .font(.caption.monospacedDigit())
        }
        .padding(12)
        .background(Color.black.opacity(0.6))
    }

    private var surfaceLabel: String {
        if viewModel.snapshot.trueDepthEverAvailable {
            return "TrueDepth face-surface distance"
        }
        return "TrueDepth face-surface distance (unavailable)"
    }

    private var screenDistanceLabel: String {
        viewModel.snapshot.screenOffsetCalibrated
            ? "Estimated screen-to-face distance — calibrated offset"
            : "Estimated screen distance — uncalibrated"
    }

    private func angleReadout(label: String, value: Double?) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value.map { String(format: "%+.1f°", $0) } ?? "—")
                .font(.title3.monospacedDigit().bold())
        }
        .frame(minWidth: 76)
    }

    @ViewBuilder
    private func distanceRow(_ label: String, _ meters: Double?,
                             signed: Bool = false, highlight: Bool = false) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(formatCentimeters(meters, signed: signed))
                .foregroundStyle(highlight ? .orange : .primary)
                .gridColumnAlignment(.trailing)
        }
    }

    private func formatCentimeters(_ meters: Double?, signed: Bool) -> String {
        guard let meters else { return "—" }
        return String(format: signed ? "%+.1f cm" : "%.1f cm", meters * 100)
    }

    // MARK: - Bottom bar: stage progress + controls

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if viewModel.snapshot.stage == .recording
                || viewModel.snapshot.stage == .paused {
                DirectionChecklist(completed: viewModel.snapshot.completedDirections)
                HStack {
                    if let guidance = viewModel.snapshot.guidance {
                        Text("Stage \(min(guidance.stageIndex + 1, guidance.stageCount)) of \(guidance.stageCount)")
                    }
                    Spacer()
                    Text(String(format: "%.0f s", viewModel.snapshot.recordingElapsedSeconds))
                    Spacer()
                    Text("accepted \(viewModel.snapshot.acceptedSampleCount) · rejected \(viewModel.snapshot.rejectedSampleCount)")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            controls
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .padding(.top, 6)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.6))
    }

    private var controls: some View {
        HStack(spacing: 12) {
            switch viewModel.snapshot.stage {
            case .preview:
                Button("Capture Neutral Pose") { viewModel.captureNeutral() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.snapshot.faceTracked)
            case .capturingNeutral:
                ProgressView()
                Text("Hold still…").font(.callout)
            case .neutralReady:
                Button("Start Head Movement Recording") { viewModel.startRecording() }
                    .buttonStyle(.borderedProminent)
                Button("Recapture Neutral") { viewModel.recaptureNeutral() }
                    .buttonStyle(.bordered)
            case .recording:
                Button("Pause") { viewModel.pauseRecording() }
                    .buttonStyle(.bordered)
                Button("Stop") { viewModel.stopRecording() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            case .paused:
                Button("Resume") { viewModel.resumeRecording() }
                    .buttonStyle(.borderedProminent)
                Button("Stop") { viewModel.stopRecording() }
                    .buttonStyle(.bordered)
                    .tint(.red)
                Button("Restart") { viewModel.restartSession() }
                    .buttonStyle(.bordered)
            case .finished:
                ProgressView()
            }
        }
        .font(.callout)
    }
}

// MARK: - Center guidance overlay

/// Everything the participant needs, arranged in a fixed ring AROUND the
/// fixation dot: a directional arrow (head-movement direction, not gaze), a
/// hold-progress ring, and one short line of text. Every element has a fixed
/// position — only colour, opacity, text, and ring fill ever change — so
/// nothing competes with the dot for fixation.
struct CenterGuidanceOverlay: View {
    let snapshot: MeasurementSnapshot

    /// Radius of the hold-progress ring (centered on the dot).
    private let ringRadius: CGFloat = 46
    /// Distance of the directional arrow from the dot.
    private let arrowRadius: CGFloat = 108
    /// Vertical offset of the instruction text below the dot.
    private let textOffset: CGFloat = 168

    var body: some View {
        ZStack {
            holdRing
            arrowLayer
            textLayer
        }
        .frame(width: 2 * (arrowRadius + 60), height: 2 * (arrowRadius + 90))
    }

    // MARK: Ring

    /// Thin progress ring around the dot: fills while a hold is in progress
    /// (target pose or neutral). Also doubles as the neutral-capture progress
    /// indicator so the eyes never need to leave the dot during capture.
    @ViewBuilder
    private var holdRing: some View {
        let progress = ringProgress
        Circle()
            .stroke(Color.white.opacity(0.15), lineWidth: 3)
            .frame(width: ringRadius * 2, height: ringRadius * 2)
        Circle()
            .trim(from: 0, to: progress)
            .stroke(ringColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .frame(width: ringRadius * 2, height: ringRadius * 2)
            .rotationEffect(.degrees(-90))
            .animation(.linear(duration: 0.1), value: progress)
    }

    private var ringProgress: Double {
        if snapshot.stage == .capturingNeutral {
            return snapshot.neutralCaptureProgress
        }
        return snapshot.guidance?.holdProgress ?? 0
    }

    private var ringColor: Color {
        guard let guidance = snapshot.guidance else { return .blue }
        if guidance.isPaused { return .orange }
        return guidance.holdProgress > 0 ? .green : .blue
    }

    // MARK: Arrow

    /// Offset direction (screen space) for each movement instruction.
    static func arrowUnitOffset(for phase: ProtocolPhase) -> CGVector? {
        let d = 1.0 / 2.0.squareRoot()
        switch phase {
        case .up: return CGVector(dx: 0, dy: -1)
        case .down: return CGVector(dx: 0, dy: 1)
        case .left: return CGVector(dx: -1, dy: 0)
        case .right: return CGVector(dx: 1, dy: 0)
        case .upperLeft: return CGVector(dx: -d, dy: -d)
        case .upperRight: return CGVector(dx: d, dy: -d)
        case .lowerLeft: return CGVector(dx: -d, dy: d)
        case .lowerRight: return CGVector(dx: d, dy: d)
        default: return nil
        }
    }

    @ViewBuilder
    private var arrowLayer: some View {
        if let guidance = snapshot.guidance, !guidance.isPaused, !guidance.isComplete {
            switch guidance.state {
            case .instructingDirection, .movingTowardTarget, .holdingTargetPose:
                if let direction = guidance.direction,
                   let unit = Self.arrowUnitOffset(for: direction),
                   let symbol = direction.symbolName {
                    Image(systemName: symbol)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(arrowColor(guidance))
                        .offset(x: unit.dx * arrowRadius, y: unit.dy * arrowRadius)
                        .accessibilityLabel("Move head \(direction.rawValue)")
                }
            case .returningToNeutral, .holdingNeutral:
                // Inward cue: four chevrons pointing back toward the dot.
                ForEach(Self.inwardChevrons, id: \.symbol) { chevron in
                    Image(systemName: chevron.symbol)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Color.cyan.opacity(0.9))
                        .offset(x: chevron.unit.dx * arrowRadius,
                                y: chevron.unit.dy * arrowRadius)
                }
                .accessibilityLabel("Return head to center")
            default:
                EmptyView()
            }
        }
    }

    private static let inwardChevrons: [(symbol: String, unit: CGVector)] = [
        ("chevron.down", CGVector(dx: 0, dy: -1)),   // above the dot, pointing down
        ("chevron.up", CGVector(dx: 0, dy: 1)),      // below, pointing up
        ("chevron.right", CGVector(dx: -1, dy: 0)),  // left, pointing right
        ("chevron.left", CGVector(dx: 1, dy: 0)),    // right, pointing left
    ]

    private func arrowColor(_ guidance: GuidanceUIState) -> Color {
        guidance.state == .holdingTargetPose ? .green : .white
    }

    // MARK: Text

    /// One short line, fixed position just below the ring — close enough to
    /// read in near-peripheral vision without leaving the dot.
    @ViewBuilder
    private var textLayer: some View {
        VStack(spacing: 4) {
            Text(primaryText)
                .font(.callout.weight(.semibold))
                .foregroundStyle(primaryTextColor)
            if let secondary = secondaryText {
                Text(secondary)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .multilineTextAlignment(.center)
        .frame(width: 280)
        .offset(y: textOffset)
    }

    private var primaryText: String {
        switch snapshot.stage {
        case .capturingNeutral:
            return "Hold still — capturing neutral"
        case .recording, .paused:
            return snapshot.guidance?.instruction ?? ""
        default:
            return "Keep your eyes on the red dot"
        }
    }

    private var primaryTextColor: Color {
        if let guidance = snapshot.guidance, guidance.isPaused { return .orange }
        return .white
    }

    private var secondaryText: String? {
        guard snapshot.stage == .recording else { return nil }
        return snapshot.guidance?.feedbackMessage
    }
}

/// Eight small static markers showing which directions have actually been
/// completed. Fixed positions, no animation — a progress record, not a
/// target. Placed at the bottom of the screen, far from the fixation dot.
struct DirectionChecklist: View {
    let completed: Set<ProtocolPhase>

    private static let order: [(ProtocolPhase, String)] = [
        (.upperLeft, "arrow.up.left"), (.up, "arrow.up"), (.upperRight, "arrow.up.right"),
        (.left, "arrow.left"), (.right, "arrow.right"),
        (.lowerLeft, "arrow.down.left"), (.down, "arrow.down"), (.lowerRight, "arrow.down.right"),
    ]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Self.order, id: \.0) { phase, symbol in
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(completed.contains(phase)
                                              ? Color.green.opacity(0.85)
                                              : Color.white.opacity(0.12)))
                    .foregroundStyle(completed.contains(phase) ? .black : .secondary)
            }
        }
        .accessibilityLabel("\(completed.count) of 8 directions completed")
    }
}

/// The single fixed circular fixation target. High-contrast red on black,
/// 16–20 pt diameter, no positional animation, no secondary dots.
struct CenterDotView: View {
    let diameter: Double

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: diameter, height: diameter)
            .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.5))
            .accessibilityLabel("Fixation dot")
    }
}
