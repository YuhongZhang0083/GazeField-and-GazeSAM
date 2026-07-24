import SwiftUI

/// Screen 1: verifies TrueDepth face-tracking support and camera permission
/// before anything else runs. Unsupported devices fail gracefully here.
struct DeviceCheckView: View {
    @EnvironmentObject private var viewModel: MeasurementViewModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "faceid")
                .font(.system(size: 56))
                .foregroundStyle(.tint)

            Text("HeadPoseDistance")
                .font(.largeTitle.bold())
            Text("Head distance & orientation measurement — Phase 1")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 14) {
                checkRow(ok: viewModel.isFaceTrackingSupported,
                         title: "TrueDepth face tracking",
                         detail: viewModel.isFaceTrackingSupported
                            ? "ARKit face tracking is supported on this device."
                            : "This device does not support the required TrueDepth face tracking.")

                checkRow(ok: viewModel.cameraPermission == .granted,
                         pending: viewModel.cameraPermission == .notDetermined,
                         title: "Camera permission",
                         detail: permissionDetail)

                if viewModel.isRunningOnSimulator {
                    checkRow(ok: false, title: "Simulator detected",
                             detail: "AR face tracking and TrueDepth measurement require a compatible physical iPhone. The app compiles here, but sensors are unavailable.")
                }
            }
            .padding()
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal)

            Text("Per-pixel TrueDepth availability is verified live once the camera starts; if unavailable, the app falls back to the ARKit head-reference distance and labels it clearly.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Spacer()

            if viewModel.cameraPermission == .notDetermined {
                Button {
                    viewModel.requestCameraPermission()
                } label: {
                    Text("Allow Camera Access")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
            }

            Button {
                viewModel.proceedToInstructions()
            } label: {
                Text("Continue")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!(viewModel.isFaceTrackingSupported && viewModel.cameraPermission == .granted))
            .padding(.horizontal)

            if viewModel.cameraPermission == .denied {
                Text("Camera access was denied. Enable it in Settings → Privacy → Camera to continue.")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Spacer(minLength: 20)
        }
        .onAppear { viewModel.refreshCameraPermission() }
    }

    private var permissionDetail: String {
        switch viewModel.cameraPermission {
        case .granted:
            return "Front camera access granted."
        case .notDetermined:
            return "The app uses the front TrueDepth camera to measure face distance and head orientation. No images are stored or transmitted."
        case .denied:
            return "Camera access denied or restricted."
        }
    }

    @ViewBuilder
    private func checkRow(ok: Bool, pending: Bool = false, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: pending ? "questionmark.circle.fill"
                    : (ok ? "checkmark.circle.fill" : "xmark.circle.fill"))
                .foregroundStyle(pending ? .yellow : (ok ? .green : .red))
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
