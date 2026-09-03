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
    /// Withheld from the wall pending purchase; enforced by drawing no walls.
    let isPaintLocked: Bool
    /// Bumped to request a still. The renderer services each distinct value once.
    let captureToken: Int
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
        // Tag the drawable sRGB, or the values reach a P3 panel unconverted and read oversaturated.
        (view.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.paint = paint
        context.coordinator.isPaintLocked = isPaintLocked
        context.coordinator.renderer.detailGain = detailGain
        context.coordinator.renderer.occluderBounds = occluderBounds
        context.coordinator.renderer.zoom = zoom
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

        /// Pulls the latest frame rather than rendering from `ARSessionDelegate`, so a slow frame
        /// in tracking cannot stall presentation.
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
