import SwiftUI
import MetalKit

/// SwiftUI wrapper around the Metal-backed live camera preview.
///
/// Renders nothing but the camera image — all guidance overlays are ordinary
/// SwiftUI views composited on top by `MeasurementView`.
struct CameraPreviewView: UIViewRepresentable {
    let renderer: CameraPreviewRenderer

    func makeUIView(context: Context) -> MTKView {
        renderer.makeMetalView()
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}

/// Placeholder shown when Metal is unavailable (simulator without a GPU
/// device) or face tracking is unsupported, so the measurement screen still
/// lays out correctly.
struct CameraPreviewUnavailableView: View {
    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 8) {
                Image(systemName: "video.slash")
                    .font(.largeTitle)
                Text("Camera preview unavailable")
                    .font(.footnote)
            }
            .foregroundStyle(.secondary)
        }
    }
}
