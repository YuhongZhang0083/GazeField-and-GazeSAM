import SwiftUI
import simd

/// Screen 8: developer debug view. Shows raw transforms, quaternions, depth
/// internals, Core Motion values, and the current validity decision. The
/// optional front-camera preview is display-only and never saved.
struct DebugView: View {
    @EnvironmentObject private var viewModel: MeasurementViewModel
    @State private var previewEnabled = false

    var body: some View {
        NavigationStack {
            List {
                Section("Session") {
                    row("Stage", viewModel.snapshot.stage.rawValue)
                    row("Tracking", viewModel.snapshot.trackingStateDescription)
                    row("Face tracked", viewModel.snapshot.faceTracked ? "yes" : "no")
                    row("Frame rate", String(format: "%.1f Hz", viewModel.snapshot.frameRateHz))
                    row("Interrupted", viewModel.snapshot.interrupted ? "yes" : "no")
                }

                Section("Transforms (column-major)") {
                    matrixView("worldFromCamera", viewModel.snapshot.worldFromCamera)
                    matrixView("worldFromFace", viewModel.snapshot.worldFromFace)
                    matrixView("cameraFromFace", viewModel.snapshot.cameraFromFace)
                    if let t = viewModel.snapshot.translation {
                        row("translation (m)", String(format: "x %.4f  y %.4f  z %.4f", t.x, t.y, t.z))
                    }
                }

                Section("Quaternions (x, y, z, w)") {
                    quatRow("raw", viewModel.snapshot.rawQuaternion)
                    quatRow("neutral", viewModel.snapshot.neutralQuaternion)
                    quatRow("relative", viewModel.snapshot.relativeQuaternion)
                }

                Section("Euler angles (deg)") {
                    eulerRow("raw (SDK-derived)", viewModel.snapshot.rawEuler)
                    eulerRow("relative (raw signs)", viewModel.snapshot.relativeEulerRaw)
                    eulerRow("relative (user convention)", viewModel.snapshot.relativeEuler)
                    row("angular velocity",
                        viewModel.snapshot.headAngularVelocityDegPerSec
                            .map { String(format: "%.1f °/s", $0) } ?? "—")
                }

                Section("TrueDepth") {
                    row("Depth data this frame", viewModel.snapshot.trueDepthAvailableThisFrame ? "yes" : "no")
                    row("Map", "\(viewModel.snapshot.depthMapWidth) x \(viewModel.snapshot.depthMapHeight)")
                    row("Format", viewModel.snapshot.depthFormatDescription)
                    row("Valid pixels", "\(viewModel.snapshot.depthValidPixelCount) / \(viewModel.snapshot.depthTotalPixelCount) (\(String(format: "%.0f", viewModel.snapshot.depthValidPixelRatio * 100))%)")
                    row("ROI", viewModel.snapshot.depthROIDescription)
                    row("Consistent w/ head ref",
                        viewModel.snapshot.depthConsistent.map { $0 ? "yes" : "NO" } ?? "—")
                    row("Screen offset", String(format: "%.1f mm%@",
                                                viewModel.snapshot.cameraBehindScreenOffsetMeters * 1000,
                                                viewModel.snapshot.screenOffsetCalibrated ? " (calibrated)" : " (uncalibrated)"))
                }

                Section("Core Motion") {
                    vecRow("rotation rate (rad/s)", viewModel.snapshot.phoneRotationRate)
                    vecRow("user accel (g)", viewModel.snapshot.phoneUserAcceleration)
                    vecRow("gravity (g)", viewModel.snapshot.phoneGravity)
                    row("attitude Δ from start",
                        viewModel.snapshot.phoneAttitudeChangeDegrees
                            .map { String(format: "%.2f°", $0) } ?? "—")
                    row("stability", viewModel.snapshot.phoneStability.label)
                }

                Section("Validation") {
                    row("Sample valid", viewModel.snapshot.sampleValid ? "yes" : "no")
                    row("Confidence", String(format: "%.2f", viewModel.snapshot.confidence))
                    row("Reasons", viewModel.snapshot.rejectionReasons.isEmpty
                        ? "—" : viewModel.snapshot.rejectionReasons.joined(separator: ", "))
                }

                Section("Front-camera preview (debug only, never saved)") {
                    Toggle("Enable preview", isOn: $previewEnabled)
                        .onChange(of: previewEnabled) { _, enabled in
                            viewModel.setDebugPreview(enabled)
                        }
                    if previewEnabled {
                        if let renderer = viewModel.previewRenderer {
                            CameraPreviewView(renderer: renderer)
                                .frame(height: 320)
                        } else if let image = viewModel.snapshot.debugPreviewImage {
                            GeometryReader { geo in
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .overlay(alignment: .topLeading) {
                                        if let roi = viewModel.snapshot.debugROIRectNormalized {
                                            // Approximate ROI overlay in the
                                            // rotated preview space.
                                            Rectangle()
                                                .stroke(Color.yellow, lineWidth: 2)
                                                .frame(width: roi.width * geo.size.width,
                                                       height: roi.height * geo.size.height)
                                                .offset(x: roi.minX * geo.size.width,
                                                        y: roi.minY * geo.size.height)
                                        }
                                    }
                            }
                            .frame(height: 320)
                        } else {
                            Text("Waiting for preview frame…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .font(.caption.monospacedDigit())
            .navigationTitle("Debug")
            .navigationBarTitleDisplayMode(.inline)
            .onDisappear {
                viewModel.setDebugPreview(false)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
    }

    @ViewBuilder
    private func matrixView(_ label: String, _ m: simd_float4x4?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).foregroundStyle(.secondary)
            if let m {
                ForEach(0..<4, id: \.self) { r in
                    Text(String(format: "%+.4f %+.4f %+.4f %+.4f",
                                m.columns.0[r], m.columns.1[r], m.columns.2[r], m.columns.3[r]))
                        .font(.system(.caption2, design: .monospaced))
                }
            } else {
                Text("—")
            }
        }
    }

    @ViewBuilder
    private func quatRow(_ label: String, _ q: simd_quatf?) -> some View {
        row(label, q.map {
            String(format: "%+.4f %+.4f %+.4f %+.4f",
                   $0.vector.x, $0.vector.y, $0.vector.z, $0.vector.w)
        } ?? "—")
    }

    @ViewBuilder
    private func eulerRow(_ label: String, _ e: EulerAngles?) -> some View {
        row(label, e.map {
            String(format: "y %+.1f  p %+.1f  r %+.1f",
                   $0.yawDegrees, $0.pitchDegrees, $0.rollDegrees)
        } ?? "—")
    }

    @ViewBuilder
    private func vecRow(_ label: String, _ v: SIMD3<Double>?) -> some View {
        row(label, v.map {
            String(format: "%+.3f %+.3f %+.3f", $0.x, $0.y, $0.z)
        } ?? "—")
    }
}
