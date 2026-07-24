import SwiftUI

/// Screen 2: experiment instructions (exact wording per protocol).
struct InstructionsView: View {
    @EnvironmentObject private var viewModel: MeasurementViewModel

    private let instructions: [String] = [
        "Place the phone on a stable stand whenever possible.",
        "Keep the phone stationary and approximately vertical.",
        "Position your face approximately 30–60 cm from the phone.",
        "Look continuously at the red dot in the center of the screen.",
        "Keep your torso approximately still.",
        "Move only your head slowly and smoothly.",
        "Do not move the phone to follow your head.",
        "Return to the center position between directional movements."
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

                    Text("During the recording you will be guided to move your head up, down, left, right, and to the four diagonals — always while looking at the same central red dot. The dot never moves and no other targets appear.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
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
}
