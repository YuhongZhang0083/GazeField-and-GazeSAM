import SwiftUI

/// Screen 2: experiment instructions (exact wording per protocol).
struct InstructionsView: View {
    @EnvironmentObject private var viewModel: MeasurementViewModel

    /// Rules that hold for both protocols.
    private let instructions: [String] = [
        "Place the phone on a stable stand whenever possible.",
        "Keep the phone stationary and approximately vertical.",
        "Position your face approximately 30–60 cm from the phone.",
        "Look continuously at the red dot in the center of the screen.",
        "Keep your torso approximately still.",
        "Move only your head slowly and smoothly.",
        "Do not move the phone to follow your head."
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Instructions")
                        .font(.largeTitle.bold())
                        .padding(.top, 24)

                    ForEach(Array(instructions.enumerated()), id: \.offset) { index, text in
                        HStack(alignment: .top, spacing: 12) {
                            Text("\(index + 1)")
                                .font(.callout.monospacedDigit().bold())
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(Color.accentColor.opacity(0.25)))
                            Text(text)
                                .font(.body)
                        }
                    }

                    protocolSection
                }
                .padding(.horizontal, 24)
            }

            Button {
                viewModel.beginMeasurement()
            } label: {
                Text("Begin Measurement")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(24)
        }
    }

    /// Protocol chooser plus the instructions specific to it. The choice lives
    /// here as well as on the measurement screen so the participant reads the
    /// steps for the protocol they are actually about to perform — the two
    /// ask for genuinely different movements.
    private var protocolSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider().padding(.vertical, 4)

            Text("Recording protocol")
                .font(.headline)

            Picker("Protocol", selection: $viewModel.recordingMode) {
                ForEach(RecordingMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            ForEach(Array(protocolSteps.enumerated()), id: \.offset) { _, text in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 5))
                        .padding(.top, 7)
                        .foregroundStyle(.secondary)
                    Text(text).font(.callout)
                }
            }

            Text("The red dot never moves, and it is the only thing you should ever look at. No other fixation targets appear.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
                .padding(.bottom, 8)
        }
    }

    private var protocolSteps: [String] {
        switch viewModel.recordingMode {
        case .spiralSweep:
            return [
                "A teal head-shaped outline appears over the middle of the screen, tilted to a target orientation.",
                "Turn your head until your head fills the outline — then keep it filled. The outline drifts slowly and continuously, spiralling outward from the centre.",
                "Your eyes never follow the outline. Keep them on the red dot the whole time; only your head turns.",
                "If you fall behind, the outline turns amber and waits for you. There is no time limit.",
                "The bar at the bottom shows how much of the spiral you have covered. It takes about 75 seconds of steady following."
            ]
        case .eightSpoke:
            return [
                "You will be guided to move your head up, down, left, right, and then to the four diagonals.",
                "An arrow shows each direction. Turn your head that way slowly, and hold it there until the ring around the centre fills.",
                "Return your head to centre between every direction, and hold there briefly.",
                "Each direction advances only when you actually reach it — never on a timer."
            ]
        }
    }
}
