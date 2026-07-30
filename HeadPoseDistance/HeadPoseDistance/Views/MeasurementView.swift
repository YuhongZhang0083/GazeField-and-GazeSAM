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
            // The fixation anchor sits in the upper third of the screen,
            // close to the TrueDepth camera: fixating there keeps the gaze
            // line near the camera axis and matches where the head/oval
            // cluster is drawn, so there is no gaze pull away from the dot.
            let anchor = CGPoint(
                x: geometry.size.width / 2,
                y: geometry.size.height * viewModel.config.dotAnchorYFraction)
            ZStack {
                Color.black.ignoresSafeArea()

                // Virtual head + head-position boundary, co-located with the
                // fixation dot. Dimmed during recording so the red dot stays
                // dominant.
                CenteredHeadBoundary(snapshot: viewModel.snapshot,
                                     opacity: headOpacity)
                    .position(anchor)

                // Coverage grid (free exploration only), co-located with the
                // dot so it can be read without looking away from it. Drawn
                // over the dimmed head, under the dot.
                if let coverage = viewModel.snapshot.guidance?.coverage {
                    CenteredCoverageGrid(coverage: coverage)
                        .position(anchor)
                }

                // Guidance ring / arrows / text, drawn around — never over —
                // the dot.
                CenterGuidanceOverlay(snapshot: viewModel.snapshot)
                    .position(anchor)

                // The single fixed fixation target, topmost, overlaid on the
                // head's center. Its position depends only on screen geometry
                // and the configured anchor fraction — never on guidance
                // state.
                CenterDotView(diameter: viewModel.config.dotDiameterPoints)
                    .position(anchor)

                VStack(spacing: 0) {
                    statusHeader
                    Spacer(minLength: 0)
                    if showsReadouts {
                        measurementPanel
                    }
                    bottomBar
                }
            }
            .onAppear {
                // Report the ACTUAL on-screen dot position (global
                // coordinates) — this is what gets recorded in the session
                // metadata, so it must match the rendered anchor exactly.
                let frame = geometry.frame(in: .global)
                viewModel.reportScreenGeometry(
                    dotCenterGlobal: CGPoint(
                        x: frame.midX,
                        y: frame.minY + frame.height
                            * viewModel.config.dotAnchorYFraction),
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

    /// How present the virtual head is. It is a positioning aid, so it fades
    /// once recording starts — and fades further in free exploration, where the
    /// coverage grid sits on top of it and must remain readable. In that mode
    /// the head is also redundant for orientation: the grid's current-cell
    /// marker already shows where the head is pointing.
    private var headOpacity: Double {
        guard viewModel.snapshot.stage == .recording else { return 1.0 }
        return viewModel.snapshot.recordingMode == .freeExploration ? 0.22 : 0.5
    }

    /// The dense numeric panel is a positioning aid, shown only before
    /// recording. During recording/paused/neutral-capture it is hidden so
    /// nothing crowds the centered dot (and so the centered instruction text
    /// never overlaps it).
    private var showsReadouts: Bool {
        switch viewModel.snapshot.stage {
        case .preview, .neutralReady: return true
        default: return false
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

    /// Protocol chooser, shown only before recording starts. Both modes stay
    /// available so a spiral session (gaze-field training data) and an
    /// eight-spoke session (held-out validation targets) can be recorded
    /// back to back on the same neutral pose.
    @ViewBuilder
    private var modePicker: some View {
        if viewModel.snapshot.stage == .neutralReady {
            VStack(spacing: 4) {
                Picker("Protocol", selection: $viewModel.recordingMode) {
                    ForEach(RecordingMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text(viewModel.recordingMode.shortDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            modePicker
            if viewModel.snapshot.stage == .recording
                || viewModel.snapshot.stage == .paused {
                // The eight-direction checklist is meaningless for free
                // exploration; that mode shows the coverage grid instead.
                if viewModel.snapshot.recordingMode == .eightSpoke {
                    DirectionChecklist(completed: viewModel.snapshot.completedDirections)
                }
                HStack {
                    if viewModel.snapshot.recordingMode == .freeExploration {
                        let coverage = viewModel.snapshot.guidance?.coverage
                        Text("\(coverage?.coveredCells ?? 0)/\(coverage?.requiredCells ?? 0) cells")
                    } else if let guidance = viewModel.snapshot.guidance {
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
                Button("Start \(viewModel.recordingMode.displayName) Recording") {
                    viewModel.startRecording()
                }
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

    /// Radius of the hold-progress ring — encircles the centered head/oval.
    private let ringRadius: CGFloat = 104
    /// Distance of the directional arrow from the dot (outside ring + oval).
    private let arrowRadius: CGFloat = 136
    /// Vertical offset of the instruction text below the dot.
    private let textOffset: CGFloat = 176

    var body: some View {
        ZStack {
            holdRing
            arrowLayer
            textLayer
        }
        .frame(width: 2 * (arrowRadius + 50), height: 2 * (arrowRadius + 70))
    }

    // MARK: Ring

    /// Thin progress ring encircling the head/oval: fills while a hold is in
    /// progress (target pose or neutral) and shows neutral-capture progress,
    /// so the eyes never need to leave the dot. Hidden before recording.
    @ViewBuilder
    private var holdRing: some View {
        if showsRing {
            let progress = ringProgress
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: 3)
                .frame(width: ringRadius * 2, height: ringRadius * 2)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(ringColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: ringRadius * 2, height: ringRadius * 2)
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.1), value: progress)
        }
    }

    private var showsRing: Bool {
        switch snapshot.stage {
        case .capturingNeutral, .recording, .paused: return true
        default: return false
        }
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
            // No standing instruction here — the setup buttons and the
            // head-position boundary provide guidance, and the fixation dot
            // needs no caption.
            return ""
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

/// The coverage grid: the whole interface for free exploration, drawn
/// **centred on the fixation dot**.
///
/// Placement is the point. At this size the grid spans roughly 2° of visual
/// angle at a 55 cm working distance, which is about the width of the fovea —
/// so the participant reads the entire grid *while fixating the dot*, with no
/// eye movement at all. The first version sat at the bottom of the screen and
/// pulled the gaze down to check progress, which contaminated exactly the
/// samples it was reporting on.
///
/// Each square is a patch of the (yaw, pitch) field: left/right is head yaw,
/// up/down is head pitch, mirrored to match the virtual head, so turning right
/// moves the marker right. A square fills in as samples accumulate there and
/// goes solid once it has enough. The thin outline is the cell the head is in
/// right now, which makes the grid read as a map rather than a meter.
struct CenteredCoverageGrid: View {
    let coverage: ExplorationGuidanceState

    /// Sized so 17 × 17 cells span 126 × 126 pt — inside the 136 × 154 pt
    /// alignment oval, and 2.2° of visual angle at 55 cm (3.0° at 41 cm), so it
    /// still fits within the fovea. Cells are 6–8 arcmin, still well above the
    /// ~1 arcmin acuity limit, so they stay individually distinguishable.
    ///
    /// Square, because the field is square: one cell is the same number of
    /// degrees horizontally and vertically, so the grid reads as an undistorted
    /// map of head direction.
    private let cellSize: CGFloat = 6
    private let spacing: CGFloat = 1.5

    var body: some View {
        VStack(spacing: spacing) {
            ForEach(0..<coverage.rows, id: \.self) { row in
                HStack(spacing: spacing) {
                    ForEach(0..<coverage.columns, id: \.self) { column in
                        cell(column: column, row: row)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Coverage \(coverage.coveredCells) of \(coverage.requiredCells) cells")
    }

    @ViewBuilder
    private func cell(column: Int, row: Int) -> some View {
        let index = row * coverage.columns + column
        let required = coverage.cellRequired.indices.contains(index)
            ? coverage.cellRequired[index] : false
        let fill = coverage.cellFill.indices.contains(index) ? coverage.cellFill[index] : 0
        let isCurrent = coverage.currentColumn == column && coverage.currentRow == row

        RoundedRectangle(cornerRadius: 2)
            .fill(color(required: required, fill: fill))
            .frame(width: cellSize, height: cellSize)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.white.opacity(isCurrent ? 0.9 : 0), lineWidth: 1.2)
            )
    }

    /// Empty → faint grey; partially sampled → dim green; complete → solid
    /// green. Cells outside the elliptical field are barely drawn: they convey
    /// the shape of the field without implying they need filling.
    private func color(required: Bool, fill: Double) -> Color {
        guard required else { return Color.white.opacity(0.05) }
        if fill >= 1 { return Color.green.opacity(0.85) }
        if fill <= 0 { return Color.white.opacity(0.16) }
        return Color.green.opacity(0.22 + 0.45 * fill)
    }
}

/// Virtual head + head-position boundary, centered so it sits directly under
/// the fixation dot (drawn on top by `MeasurementView`). This co-location is
/// deliberate: the participant looks at the red dot and their head
/// representation is right there, instead of being pulled up to a
/// top-of-screen oval (which biased the neutral pitch baseline).
///
/// The oval is a FIXED frame that the head should fill at the right distance;
/// it never moves. The head inside rotates/shifts/scales with measured
/// tracking data only.
struct CenteredHeadBoundary: View {
    let snapshot: MeasurementSnapshot
    /// Set by the caller: the head recedes during recording so the red dot
    /// stays dominant, and recedes further in free exploration, where the
    /// coverage grid is drawn on top of it and must stay legible.
    var opacity: Double

    // The oval hugs the head with a small margin at the neutral distance
    // (the head fills ~85% of its frame — see VirtualHeadView's
    // orthographicScale); moving closer/farther scales the head so it
    // overflows or shrinks inside the fixed oval.
    private let ovalSize = CGSize(width: 136, height: 154)
    private let headSize = CGSize(width: 150, height: 168)

    var body: some View {
        ZStack {
            Ellipse()
                .stroke(boundaryColor.opacity(0.9),
                        style: StrokeStyle(lineWidth: 2, dash: aligned ? [] : [5, 4]))
                .frame(width: ovalSize.width, height: ovalSize.height)

            VirtualHeadView(
                yawDegrees: snapshot.relativeEuler?.yawDegrees ?? 0,
                pitchDegrees: snapshot.relativeEuler?.pitchDegrees ?? 0,
                rollDegrees: snapshot.relativeEuler?.rollDegrees ?? 0,
                userRightOffsetMeters: snapshot.alignment.userRightOffsetMeters,
                userUpOffsetMeters: snapshot.alignment.userUpOffsetMeters,
                distanceDeviationMeters: snapshot.distanceDeviationMeters,
                faceTracked: snapshot.faceTracked)
                .frame(width: headSize.width, height: headSize.height)

            // Alignment cue sits ABOVE the hold ring (radius 104 in
            // CenterGuidanceOverlay) so it overlaps neither dot nor ring.
            if let cue = cueText {
                Text(cue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(aligned ? Color.secondary : Color.orange)
                    .offset(y: -122)
            }
        }
        .opacity(opacity)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Head position: \(cueText ?? "aligned")")
    }

    private var aligned: Bool { snapshot.alignment.isAligned }

    private var boundaryColor: Color {
        if !snapshot.faceTracked { return .red }
        return aligned ? .green : .orange
    }

    /// Correction cue. During recording it stays silent while aligned so it
    /// doesn't nag; during setup it always shows so the user can position.
    private var cueText: String? {
        if snapshot.stage == .recording, aligned { return nil }
        return snapshot.alignment.cue
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
            // A soft dark halo keeps the dot readable over the virtual head.
            .shadow(color: .black.opacity(0.8), radius: 5)
            .accessibilityLabel("Fixation dot")
    }
}
