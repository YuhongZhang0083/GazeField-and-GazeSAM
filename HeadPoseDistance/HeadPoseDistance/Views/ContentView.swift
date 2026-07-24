import SwiftUI

/// Root navigation between the app's screens. All state lives in the view
/// model; this view only switches on the current phase.
struct ContentView: View {
    @EnvironmentObject private var viewModel: MeasurementViewModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch viewModel.appPhase {
            case .deviceCheck:
                DeviceCheckView()
            case .instructions:
                InstructionsView()
            case .measurement:
                MeasurementView()
            case .results:
                if let session = viewModel.lastSession {
                    ResultsView(session: session)
                } else {
                    // Should not happen; recover gracefully.
                    DeviceCheckView()
                }
            }
        }
    }
}
