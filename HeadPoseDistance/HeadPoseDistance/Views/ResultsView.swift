import SwiftUI
import Charts

/// Screens 6–7: session results and data export. Simple native time-series
/// traces only — no gaze maps, no heat maps.
struct ResultsView: View {
    @EnvironmentObject private var viewModel: MeasurementViewModel
    let session: RecordedSession

    @State private var includeRejected = false

    // Fixed 3-slot categorical palette (colorblind-validated for the dark
    // surface; assigned in fixed order, never cycled).
    private static let yawColor = Color(red: 57 / 255, green: 135 / 255, blue: 229 / 255)
    private static let pitchColor = Color(red: 217 / 255, green: 89 / 255, blue: 38 / 255)
    private static let rollColor = Color(red: 25 / 255, green: 158 / 255, blue: 112 / 255)

    private struct AnglePoint: Identifiable {
        let id = UUID()
        let time: Double
        let degrees: Double
        let series: String
    }

    private struct DistancePoint: Identifiable {
        let id = UUID()
        let time: Double
        let centimeters: Double
    }

    var body: some View {
        NavigationStack {
            List {
                summarySection
                distanceSection
                angleSection
                chartSection
                exportSection

                Section {
                    Button("New Session") {
                        viewModel.restartSession()
                    }
                }
            }
            .navigationTitle("Session Results")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Summary

    private var summarySection: some View {
        Section("Recording") {
            row("Duration", String(format: "%.1f s", session.summary.durationSeconds))
            row("Total samples", "\(session.summary.totalSamples)")
            row("Accepted", "\(session.summary.acceptedSamples)")
            row("Rejected", "\(session.summary.rejectedSamples)")
            row("Mean sampling rate", String(format: "%.1f Hz", session.summary.meanSamplingRateHz))
            row("Phone stable", String(format: "%.0f%% of samples", session.summary.phoneStablePercentage))
            row("Valid TrueDepth", String(format: "%.0f%% of samples", session.summary.validTrueDepthPercentage))
            if !session.summary.rejectionReasonCounts.isEmpty {
                let top = session.summary.rejectionReasonCounts
                    .sorted { $0.value > $1.value }
                    .prefix(3)
                    .map { "\($0.key) (\($0.value))" }
                    .joined(separator: ", ")
                row("Top flags", top)
            }
        }
    }

    private var distanceSection: some View {
        Section("Distance") {
            row("Median head reference",
                formatCm(session.summary.medianHeadReferenceDistanceMeters))
            row("Median TrueDepth face-surface",
                formatCm(session.summary.medianSurfaceDistanceMeters))
            row(session.metadata.screenOffsetCalibrated
                    ? "Median est. screen-to-face (calibrated offset)"
                    : "Median est. screen distance (uncalibrated)",
                formatCm(session.summary.medianEstimatedScreenDistanceMeters))
            row("Std deviation", formatCm(session.summary.distanceStandardDeviationMeters))
            row("Range", rangeText)
        }
    }

    private var rangeText: String {
        guard let lo = session.summary.distanceMinMeters,
              let hi = session.summary.distanceMaxMeters else { return "—" }
        return String(format: "%.1f – %.1f cm", lo * 100, hi * 100)
    }

    private var angleSection: some View {
        Section("Head rotation (relative to neutral)") {
            row("Max |yaw|", formatDeg(session.summary.maxAbsoluteRelativeYawDegrees))
            row("Max |pitch|", formatDeg(session.summary.maxAbsoluteRelativePitchDegrees))
            row("Max |roll|", formatDeg(session.summary.maxAbsoluteRelativeRollDegrees))
        }
    }

    // MARK: - Charts

    private var chartSection: some View {
        Section("Traces") {
            if anglePoints.isEmpty {
                Text("No accepted samples with orientation data.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Head rotation over time (deg)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Chart(anglePoints) { point in
                        LineMark(x: .value("Time (s)", point.time),
                                 y: .value("Degrees", point.degrees))
                            .foregroundStyle(by: .value("Angle", point.series))
                            .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    .chartForegroundStyleScale([
                        "Yaw": Self.yawColor,
                        "Pitch": Self.pitchColor,
                        "Roll": Self.rollColor
                    ])
                    .chartXAxisLabel("Time (s)")
                    .frame(height: 190)
                }
                .padding(.vertical, 4)
            }

            if distancePoints.isEmpty {
                Text("No accepted samples with distance data.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(distanceTraceTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Chart(distancePoints) { point in
                        LineMark(x: .value("Time (s)", point.time),
                                 y: .value("Distance (cm)", point.centimeters))
                            .foregroundStyle(Self.yawColor)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    .chartXAxisLabel("Time (s)")
                    .frame(height: 150)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var distanceTraceTitle: String {
        session.metadata.trueDepthSurfaceAvailable
            ? "TrueDepth face-surface distance over time (cm)"
            : "Head reference distance over time (cm)"
    }

    /// Downsampled (≤ 300 per series) accepted-sample angle traces.
    private var anglePoints: [AnglePoint] {
        let samples = downsampled(session.acceptedSamples, target: 300)
        var points: [AnglePoint] = []
        points.reserveCapacity(samples.count * 3)
        for s in samples {
            guard let yaw = s.relativeYawDegrees,
                  let pitch = s.relativePitchDegrees,
                  let roll = s.relativeRollDegrees else { continue }
            points.append(AnglePoint(time: s.sessionElapsedSeconds, degrees: yaw, series: "Yaw"))
            points.append(AnglePoint(time: s.sessionElapsedSeconds, degrees: pitch, series: "Pitch"))
            points.append(AnglePoint(time: s.sessionElapsedSeconds, degrees: roll, series: "Roll"))
        }
        return points
    }

    private var distancePoints: [DistancePoint] {
        let samples = downsampled(session.acceptedSamples, target: 300)
        return samples.compactMap { s in
            let meters = s.trueDepthSurfaceRawMeters ?? s.headReferenceDistanceMeters
            guard let meters else { return nil }
            return DistancePoint(time: s.sessionElapsedSeconds, centimeters: meters * 100)
        }
    }

    private func downsampled(_ samples: [MeasurementSample], target: Int) -> [MeasurementSample] {
        guard samples.count > target, target > 0 else { return samples }
        let stride = Double(samples.count) / Double(target)
        return (0..<target).map { samples[Int(Double($0) * stride)] }
    }

    // MARK: - Export

    private var exportSection: some View {
        Section("Data Export") {
            Toggle("Include rejected samples (debug export)", isOn: $includeRejected)
            Button {
                viewModel.exportLastSession(includeRejected: includeRejected)
            } label: {
                Label("Generate CSV + JSON", systemImage: "doc.badge.gearshape")
            }
            ForEach(viewModel.exportedFiles) { file in
                ShareLink(item: file.url) {
                    Label(file.label, systemImage: "square.and.arrow.up")
                }
            }
            if let error = viewModel.exportErrorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            Text("Exports contain numerical measurements and session metadata only — no images, meshes, or biometric templates.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Formatting

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .font(.callout.monospacedDigit())
        }
        .font(.callout)
    }

    private func formatCm(_ meters: Double?) -> String {
        guard let meters else { return "—" }
        return String(format: "%.1f cm", meters * 100)
    }

    private func formatDeg(_ degrees: Double?) -> String {
        guard let degrees else { return "—" }
        return String(format: "%.1f°", degrees)
    }
}
