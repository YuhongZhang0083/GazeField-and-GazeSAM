import Foundation
import CoreImage
import CoreVideo
import Metal
import MetalKit
import QuartzCore

/// GPU-backed live preview of the front TrueDepth camera image.
///
/// Frames arrive from the AR session queue (`submit(pixelBuffer:)`) and are
/// drawn on the MetalKit render thread. Only the most recent buffer is kept —
/// if the renderer falls behind, intermediate frames are dropped rather than
/// queued, so the preview can never add latency to the measurement pipeline.
///
/// The camera image is **never written to disk and never leaves the device**;
/// this class only draws it into a drawable for on-screen display.
final class CameraPreviewRenderer: NSObject, MTKViewDelegate {

    /// Debug-only preview: disabled by default; the normal measurement
    /// workflow never turns it on. When false, submitted frames are ignored
    /// so no ARKit buffer is retained.
    var isEnabled = false

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let ciContext: CIContext

    /// Guards `latestBuffer`, which is written on the AR queue and read on the
    /// render thread.
    private let bufferLock = NSLock()
    private var latestBuffer: CVPixelBuffer?

    /// Backing store for `measuredFrameRate`, guarded by `bufferLock`.
    private var lastSubmitTime: CFTimeInterval = 0
    private var frameIntervalEMA: Double = 0

    /// Smoothed preview frame rate in Hz, for the debug screen.
    var measuredFrameRate: Double {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return frameIntervalEMA > 0 ? 1.0 / frameIntervalEMA : 0
    }

    /// Returns nil on devices/simulators without a usable Metal device, so the
    /// UI can fall back to a plain background instead of crashing.
    static func make() -> CameraPreviewRenderer? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        return CameraPreviewRenderer(device: device, commandQueue: queue)
    }

    private init(device: MTLDevice, commandQueue: MTLCommandQueue) {
        self.device = device
        self.commandQueue = commandQueue
        self.ciContext = CIContext(mtlDevice: device,
                                   options: [.cacheIntermediates: false,
                                             .name: "HeadPoseDistance.preview"])
        super.init()
    }

    func makeMetalView() -> MTKView {
        let view = MTKView(frame: .zero, device: device)
        view.delegate = self
        view.framebufferOnly = false          // CIContext renders into the drawable
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 30    // half of ARKit's 60 Hz — plenty for a preview
        view.autoResizeDrawable = true
        view.isOpaque = true
        view.contentMode = .scaleAspectFill
        view.isUserInteractionEnabled = false
        return view
    }

    /// Called on the AR session queue for every frame. Retains only the newest
    /// buffer; the previous one is released immediately.
    ///
    /// The buffer is referenced rather than copied: ARKit may recycle it from
    /// its pool while we still hold it, which can very occasionally tear a
    /// preview frame. That is an acceptable trade for zero per-frame copy cost
    /// on a display-only image — no measurement ever reads from here.
    func submit(pixelBuffer: CVPixelBuffer) {
        guard isEnabled else { return }
        let now = CACurrentMediaTime()
        bufferLock.lock()
        latestBuffer = pixelBuffer
        if lastSubmitTime > 0 {
            let dt = now - lastSubmitTime
            // Same EMA smoothing the pipeline uses for its own frame rate.
            frameIntervalEMA = frameIntervalEMA > 0 ? frameIntervalEMA * 0.9 + dt * 0.1 : dt
        }
        lastSubmitTime = now
        bufferLock.unlock()
    }

    /// Drops the retained frame — call when the preview is hidden or the
    /// session stops so the last image does not linger on screen.
    func clear() {
        bufferLock.lock()
        latestBuffer = nil
        bufferLock.unlock()
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard isEnabled,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        bufferLock.lock()
        let buffer = latestBuffer
        bufferLock.unlock()

        guard let buffer else { return }

        let drawableSize = CGSize(width: drawable.texture.width,
                                  height: drawable.texture.height)
        let image = Self.orientedForPortraitSelfie(CIImage(cvPixelBuffer: buffer))
        let filled = Self.aspectFill(image, into: drawableSize)

        ciContext.render(filled,
                         to: drawable.texture,
                         commandBuffer: commandBuffer,
                         bounds: CGRect(origin: .zero, size: drawableSize),
                         colorSpace: CGColorSpaceCreateDeviceRGB())
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Geometry (pure, unit-testable)

    /// The front camera delivers landscape-oriented buffers. Rotating 90° CW
    /// (`.right`) yields an upright portrait image; a horizontal flip then
    /// makes it a mirror view, which is what users expect of a selfie preview
    /// and what makes "turn left" match the direction they see themselves move.
    static func orientedForPortraitSelfie(_ image: CIImage) -> CIImage {
        let upright = image.oriented(.right)
        let extent = upright.extent
        return upright
            .transformed(by: CGAffineTransform(scaleX: -1, y: 1))
            .transformed(by: CGAffineTransform(translationX: extent.maxX + extent.minX, y: 0))
    }

    /// Scales `image` to cover `target` completely (preserving aspect ratio)
    /// and centers it, matching `UIView.ContentMode.scaleAspectFill`.
    static func aspectFill(_ image: CIImage, into target: CGSize) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0,
              target.width > 0, target.height > 0 else { return image }

        let scale = max(target.width / extent.width, target.height / extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let scaledExtent = scaled.extent
        let dx = (target.width - scaledExtent.width) / 2 - scaledExtent.minX
        let dy = (target.height - scaledExtent.height) / 2 - scaledExtent.minY
        return scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))
    }
}
