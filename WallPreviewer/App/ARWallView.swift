import ARKit
import MetalKit
import SwiftUI
import simd

/// Hosts the Metal view that renders the AR feed, bridging it into SwiftUI.
struct ARWallView: UIViewRepresentable {

    let controller: ARSessionController
    let calibration: CaptureCalibration
    let renderer: WallRenderer
    let paint: PaintColor
    let detailGain: Float
    let occluderBounds: OccluderBounds
    let zoom: Float
    /// Whether the selected colour is withheld from the wall pending purchase.
    ///
    /// Enforced by drawing no walls, which routes through the same path as having none selected:
    /// the composite passes the camera through untouched. Withholding it here rather than in the
    /// UI is what makes the gate real — every other approach leaves the paint reaching the
    /// renderer and merely hides it.
    let isPaintLocked: Bool
    /// Bumped to request a still. The renderer services each distinct value once.
    let captureToken: Int
    /// Main-actor isolated, matching `WallRenderer.onCapture`: that isolation is what makes the
    /// closure `Sendable`, and therefore legal to hand to a GPU completion handler.
    let onCapture: @MainActor (CGImage?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller, calibration: calibration, renderer: renderer)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.metalDevice)
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.preferredFramesPerSecond = 60
        view.isOpaque = true
        // Tag the drawable as sRGB. `MTKView.colorspace` is macOS-only, but the underlying
        // layer exposes it on iOS. This is not cosmetic: an untagged layer gets no colour
        // matching, so sRGB values would be pushed unconverted to a Display P3 panel and read
        // oversaturated — which would corrupt the very thing this demo is measuring.
        (view.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.paint = paint
        context.coordinator.isPaintLocked = isPaintLocked
        context.coordinator.renderer.detailGain = detailGain
        context.coordinator.renderer.occluderBounds = occluderBounds
        context.coordinator.renderer.zoom = zoom
        // Safe to assign unconditionally: the renderer gates on the token, so repeated updates
        // with the same value are no-ops.
        context.coordinator.renderer.onCapture = onCapture
        context.coordinator.renderer.captureToken = captureToken
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        let controller: ARSessionController
        let calibration: CaptureCalibration
        let renderer: WallRenderer
        var paint: PaintColor = PaintCatalog.default
        var isPaintLocked = false

        init(controller: ARSessionController, calibration: CaptureCalibration, renderer: WallRenderer) {
            self.controller = controller
            self.calibration = calibration
            self.renderer = renderer
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        /// Pulls the latest frame rather than rendering from `ARSessionDelegate`.
        ///
        /// Driving from the display link keeps rendering at the panel's cadence and decouples it
        /// from ARKit's callback rate, so a slow frame in tracking cannot stall presentation.
        func draw(in view: MTKView) {
            guard let frame = controller.session.currentFrame else { return }
            calibration.update(with: frame)

            let orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
            renderer.draw(frame: frame,
                          walls: isPaintLocked ? [] : controller.selectedWallGroup,
                          openings: controller.excludesOpenings
                              ? Array(controller.openings.values)
                              : [],
                          paint: linearPaint(),
                          in: view,
                          orientation: orientation)
        }

        /// Resolves the catalogue colour into linear sRGB under the current scene illuminant.
        private func linearPaint() -> SIMD3<Float> {
            let xyz = paint.adaptedReflectance(under: calibration.illuminant)
            return simd_max(ColorScience.xyzToSRGB * xyz, .zero)
        }
    }
}
