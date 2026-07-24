import SwiftUI

/// Optional one-point screen-distance calibration.
///
/// TrueDepth measures distance to the front CAMERA. To estimate distance to
/// the display surface, the user measures their screen-to-face distance with
/// a ruler, enters it here, and the app records stable TrueDepth samples:
///
///     offset = median(camera depth) − entered screen distance
///
/// The offset is stored per device and can be reset.
struct CalibrationSheet: View {
    @EnvironmentObject private var viewModel: MeasurementViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var referenceText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("1. Sit still and keep your face tracked.\n2. Measure the straight-line distance from the SCREEN to your face (nose bridge) with a ruler.\n3. Enter it below in centimeters and start.")
                        .font(.footnote)
                }

                Section("Reference distance (screen to face)") {
                    TextField("e.g. 45.0", text: $referenceText)
                        .keyboardType(.decimalPad)
                    Button("Start Offset Calibration") {
                        if let cm = Double(referenceText.replacingOccurrences(of: ",", with: ".")),
                           cm > 10, cm < 120 {
                            viewModel.beginOffsetCalibration(referenceCentimeters: cm)
                        } else {
                            viewModel.offsetCalibrationMessage =
                                "Enter a distance between 10 and 120 cm."
                        }
                    }
                    .disabled(viewModel.snapshot.offsetCalibrationActive)

                    if viewModel.snapshot.offsetCalibrationActive {
                        ProgressView(value: viewModel.snapshot.offsetCalibrationProgress) {
                            Text("Collecting stable TrueDepth samples…")
                        }
                    }
                }

                Section("Current state") {
                    LabeledContent("Offset",
                                   value: String(format: "%.1f mm",
                                                 viewModel.screenOffsetMeters * 1000))
                    LabeledContent("Status",
                                   value: viewModel.screenOffsetCalibrated
                                        ? "Calibrated" : "Uncalibrated (offset 0)")
                    Button("Reset Offset", role: .destructive) {
                        viewModel.resetOffsetCalibration()
                    }
                }

                if let message = viewModel.offsetCalibrationMessage {
                    Section {
                        Text(message).font(.footnote)
                    }
                }
            }
            .navigationTitle("Screen-Distance Offset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
