import ARKit
import Metal
import MetalKit
import MetalPerformanceShaders
import simd

/// Mask-stability tuning, shared by the uniform defaults and the renderer.
///
/// Nonisolated on purpose: `WallUniforms` is a nonisolated struct, so its default values cannot
/// reach a constant that lives on the `@MainActor` renderer.
enum MaskTuning {

    /// Weight given to the incoming mask each frame. Lower is steadier and slower to respond.
    static let historyBlend: Float = 0.22

    /// Extra depth tolerance for a fragment that was wall last frame, in metres.
    static let hysteresisSlack: Float = 0.012

    /// Permitted departure of the measured depth field from the fitted plane, in metres.
    ///
    /// Tightening it erodes genuine wall boundaries, since the test reads a few depth texels out;
    /// loosening it lets paint creep onto ceilings and adjoining walls, which a depth comparison
    /// alone cannot reject near a junction.
    static let planarityTolerance: Float = 0.02

    /// Width of the alpha ramp around half coverage.
    static let edgeFeather: Float = 0.5
}

/// GPU-side layout mirror of `WallUniforms` in Shaders.metal.
///
/// - Important: every member is 16-byte aligned and a multiple of 16 long. That is deliberate —
///   MSL packs `float3` into 12 bytes where Swift's `SIMD3` takes 16, so a scalar placed after one
///   lands at a different offset on each side. Grouping scalars into `SIMD4` removes the question.
///   Offsets and stride are asserted at init.
struct WallUniforms {
    var modelViewProjection = matrix_identity_float4x4
    var cameraUVTransform = matrix_identity_float3x3
    /// This frame's screen UV to the previous frame's, for points on the painted plane.
    var reprojection = matrix_identity_float3x3
    /// xyz paint reflectance, linear and illuminant-adapted; w mean linear luma inside the mask.
    var paint = SIMD4<Float>(0.8, 0.8, 0.8, 0.25)
    /// xyz mean linear RGB inside the mask; w digital zoom.
    var meanWall = SIMD4<Float>(0.25, 0.25, 0.25, 1)
    /// xy viewport in pixels; z detail gain; w edge feather.
    var viewport = SIMD4<Float>(1, 1, 0.6, MaskTuning.edgeFeather)
    /// xy one depth texel in screen UV; z occluder band; w occluder ramp.
    var edges = SIMD4<Float>(1.0 / 256, 1.0 / 256,
                             OccluderBounds.default.band,
                             OccluderBounds.default.rampWidth)
    /// x depth-proportional slack; y hysteresis slack; z planarity tolerance; w history blend.
    var tuning = SIMD4<Float>(OccluderBounds.default.rangeTolerance,
                              MaskTuning.hysteresisSlack,
                              MaskTuning.planarityTolerance,
                              1)
}

/// Named access to the packed fields, so call sites read as though the scalars were separate.
extension WallUniforms {

    var paintLinear: SIMD3<Float> {
        get { SIMD3(paint.x, paint.y, paint.z) }
        set { paint.x = newValue.x; paint.y = newValue.y; paint.z = newValue.z }
    }

    var meanWallLuma: Float {
        get { paint.w }
        set { paint.w = newValue }
    }

    var meanWallRGB: SIMD3<Float> {
        get { SIMD3(meanWall.x, meanWall.y, meanWall.z) }
        set { meanWall.x = newValue.x; meanWall.y = newValue.y; meanWall.z = newValue.z }
    }

    /// Digital zoom. Crops the camera sample and scales the geometry to match; 1 is native.
    var zoom: Float {
        get { meanWall.w }
        set { meanWall.w = newValue }
    }

    var viewportSize: SIMD2<Float> {
        get { SIMD2(viewport.x, viewport.y) }
        set { viewport.x = newValue.x; viewport.y = newValue.y }
    }

    var detailGain: Float {
        get { viewport.z }
        set { viewport.z = newValue }
    }

    /// Width of the alpha ramp, centred on half coverage.
    var edgeFeather: Float {
        get { viewport.w }
        set { viewport.w = newValue }
    }

    var bilateralStep: SIMD2<Float> {
        get { SIMD2(edges.x, edges.y) }
        set { edges.x = newValue.x; edges.y = newValue.y }
    }

    /// How far in front of the fitted plane a fragment may sit and still be treated as wall.
    var occluderBand: Float {
        get { edges.z }
        set { edges.z = newValue }
    }

    /// Width of the fall-off above `occluderBand`.
    var occluderRamp: Float {
        get { edges.w }
        set { edges.w = newValue }
    }

    /// Depth-proportional slack added to `occluderBand`.
    var occluderRange: Float {
        get { tuning.x }
        set { tuning.x = newValue }
    }

    /// Extra depth tolerance granted to a fragment that was wall last frame.
    var hysteresisSlack: Float {
        get { tuning.y }
        set { tuning.y = newValue }
    }

    /// How far the measured depth field may depart from the fitted plane, in metres.
    var planarityTolerance: Float {
        get { tuning.z }
        set { tuning.z = newValue }
    }

    /// Weight given to this frame's mask. 1 discards the history entirely.
    var historyBlend: Float {
        get { tuning.w }
        set { tuning.w = newValue }
    }
}

/// The depth bounds that decide wall from object.
///
/// - `band` — protrusion at which a surface stops counting as wall. Below it, fully painted.
/// - `rampWidth` — how much further out the transition takes to complete.
struct OccluderBounds: Equatable, Sendable {

    /// Protrusion at which paint starts to fall away, in metres.
    var band: Float
    /// Extra protrusion over which it finishes falling away, in metres.
    var rampWidth: Float
    /// Additional tolerance per metre of range, dimensionless.
    ///
    /// LiDAR error grows with distance. At 0.015 this adds ~1.5 cm at 1 m and ~6 cm at 4 m.
    var rangeTolerance: Float = 0.015

    /// Everything at least this far off the wall is fully excluded.
    var fullyExcludedAt: Float { band + rampWidth }

    /// Excludes anything 4 cm or more off the surface, leaving trim and switch plates painted.
    static let `default` = OccluderBounds(band: 0.02, rampWidth: 0.02, rangeTolerance: 0.015)

    /// Range offered to the tuning slider.
    static let range: ClosedRange<Float> = 0.005...0.08

    var summary: String {
        String(format: "paints < %.0f cm · excludes ≥ %.0f cm (at 2 m)",
               (band + rangeTolerance * 2) * 100,
               (fullyExcludedAt + rangeTolerance * 2) * 100)
    }
}

/// Renders the camera feed with the selected wall plane repainted.
///
/// Five stages per frame: rasterise the wall mask with depth, planarity and occlusion tests; blend
/// it with the previous frame's mask reprojected through the wall plane; blur that under normalised
/// convolution to recover the shading field; reduce it to a mean; composite.
@MainActor
final class WallRenderer: NSObject {

    private let device: MTLDevice
    /// Exposed so the SwiftUI host can build its `MTKView` on the same device.
    var metalDevice: MTLDevice { device }
    private let queue: MTLCommandQueue
    private let maskPipeline: MTLRenderPipelineState
    private let openingPipeline: MTLRenderPipelineState
    private let resolvePipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private let textureCache: CVMetalTextureCache

    /// Absent where Metal Performance Shaders is unavailable, which means the Simulator.
    private let blur: MPSImageGaussianBlur?
    private let meanReduce: MPSImageStatisticsMean?

    /// This frame's rasterised mask, before any temporal filtering.
    private var rawMaskTexture: MTLTexture?
    /// The resolved mask everything downstream reads. Swapped with `historyTexture` each frame.
    private var maskTexture: MTLTexture?
    /// Last frame's resolved mask.
    private var historyTexture: MTLTexture?
    private var blurTexture: MTLTexture?
    private var meanTexture: MTLTexture?
    private var drawableSize = CGSize(width: 1, height: 1)

    // Temporal state. The history is only usable while it describes the same plane seen from a
    // known previous pose, so each of these has to match before it can be blended in.
    private var previousViewProjection: simd_float4x4?
    private var previousZoom: Float = 1
    private var previousWallID: UUID?
    private var hasHistory = false

    /// Retained across frames: the readback costs one frame of latency.
    private var meanWallLuma: Float = 0.25
    /// Mean linear colour inside the mask, used to normalise the illuminant tint to neutral.
    private var meanWallRGB = SIMD3<Float>(repeating: 0.25)

    // Live render controls, set from the UI.
    var uniforms = WallUniforms()
    var detailGain: Float = 0.6
    var occluderBounds = OccluderBounds.default
    var zoom: Float = 1

    /// Incremented by the UI to request a still. One capture per distinct value.
    var captureToken: Int = 0

    /// Where a completed still is delivered. `nil` argument means readback failed.
    var onCapture: (@MainActor (CGImage?) -> Void)?

    /// Last token acted on, so a request is serviced exactly once.
    private var servicedCaptureToken = 0

    /// Stand-in bound at the depth slot when ARKit has no depth for this frame: Metal API
    /// Validation aborts on a declared texture argument with nothing bound.
    private lazy var placeholderDepth: MTLTexture? = {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: 1, height: 1, mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        return device.makeTexture(descriptor: descriptor)
    }()

    /// Destination for the drawable copy. Sized lazily to match the drawable.
    private var captureTexture: MTLTexture?

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else { return nil }
        self.device = device
        self.queue = queue

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { return nil }
        self.textureCache = cache

        // Mask target: .r coverage, .gba mask-weighted linear RGB.
        let maskDescriptor = MTLRenderPipelineDescriptor()
        maskDescriptor.vertexFunction = library.makeFunction(name: "wallMaskVertex")
        maskDescriptor.fragmentFunction = library.makeFunction(name: "wallMaskFragment")
        maskDescriptor.colorAttachments[0].pixelFormat = .rgba16Float

        let openingDescriptor = MTLRenderPipelineDescriptor()
        openingDescriptor.vertexFunction = library.makeFunction(name: "openingMaskVertex")
        openingDescriptor.fragmentFunction = library.makeFunction(name: "openingMaskFragment")
        openingDescriptor.colorAttachments[0].pixelFormat = .rgba16Float

        let resolveDescriptor = MTLRenderPipelineDescriptor()
        resolveDescriptor.vertexFunction = library.makeFunction(name: "fullscreenVertex")
        resolveDescriptor.fragmentFunction = library.makeFunction(name: "resolveFragment")
        resolveDescriptor.colorAttachments[0].pixelFormat = .rgba16Float

        let compositeDescriptor = MTLRenderPipelineDescriptor()
        compositeDescriptor.vertexFunction = library.makeFunction(name: "fullscreenVertex")
        compositeDescriptor.fragmentFunction = library.makeFunction(name: "compositeFragment")
        compositeDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        do {
            maskPipeline = try device.makeRenderPipelineState(descriptor: maskDescriptor)
            openingPipeline = try device.makeRenderPipelineState(descriptor: openingDescriptor)
            resolvePipeline = try device.makeRenderPipelineState(descriptor: resolveDescriptor)
            compositePipeline = try device.makeRenderPipelineState(descriptor: compositeDescriptor)
        } catch {
            assertionFailure("Pipeline creation failed: \(error)")
            return nil
        }

        if MPSSupportsMTLDevice(device) {
            // Radius in pixels at mask resolution: erases wall texture, keeps a real shadow edge.
            let gaussian = MPSImageGaussianBlur(device: device, sigma: 24)
            gaussian.edgeMode = .clamp
            blur = gaussian
            meanReduce = MPSImageStatisticsMean(device: device)
        } else {
            blur = nil
            meanReduce = nil
        }

        super.init()

        // The MSL side carries a matching static_assert on the total, so a divergence is caught at
        // shader-compile time; these locate it to a field.
        assert(MemoryLayout<WallUniforms>.stride == 240,
               "WallUniforms stride \(MemoryLayout<WallUniforms>.stride) != MSL layout (240)")
        assert(MemoryLayout<WallUniforms>.offset(of: \.cameraUVTransform) == 64)
        assert(MemoryLayout<WallUniforms>.offset(of: \.reprojection) == 112)
        assert(MemoryLayout<WallUniforms>.offset(of: \.paint) == 160)
        assert(MemoryLayout<WallUniforms>.offset(of: \.meanWall) == 176)
        assert(MemoryLayout<WallUniforms>.offset(of: \.viewport) == 192)
        assert(MemoryLayout<WallUniforms>.offset(of: \.edges) == 208)
        assert(MemoryLayout<WallUniforms>.offset(of: \.tuning) == 224)
    }

    // MARK: - Texture management

    private func ensureTargets(size: CGSize) {
        guard size != drawableSize || maskTexture == nil else { return }
        drawableSize = size

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: max(Int(size.width), 1),
            height: max(Int(size.height), 1),
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        maskTexture = device.makeTexture(descriptor: descriptor)
        blurTexture = device.makeTexture(descriptor: descriptor)

        let meanDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false
        )
        meanDescriptor.usage = [.shaderRead, .shaderWrite]
        meanDescriptor.storageMode = .shared   // read back on CPU
        meanTexture = device.makeTexture(descriptor: meanDescriptor)
    }

    private func texture(from buffer: CVPixelBuffer,
                         plane: Int,
                         format: MTLPixelFormat) -> MTLTexture? {
        let width = CVPixelBufferGetWidthOfPlane(buffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, buffer, nil, format, width, height, plane, &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture else { return nil }
        return CVMetalTextureGetTexture(cvTexture)
    }

    /// Size of one depth texel in viewport UV, which sets the edge-refinement radius.
    ///
    /// - Note: assumes portrait, which the target is locked to.
    private func bilateralStep(depth: MTLTexture?, viewport: SIMD2<Float>) -> SIMD2<Float> {
        guard let depth, viewport.x > 0, viewport.y > 0 else { return SIMD2<Float>(1.0 / 256, 1.0 / 256) }
        // Depth texels are square in the camera image, so only the UV normalisation differs.
        let stepY = 1.0 / Float(max(depth.width, depth.height))
        return SIMD2<Float>(stepY * viewport.y / viewport.x, stepY)
    }

    private func depthTexture(from frame: ARFrame) -> MTLTexture? {
        guard let depth = frame.smoothedSceneDepth ?? frame.sceneDepth else { return nil }
        let map = depth.depthMap
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, map, nil, .r32Float,
            CVPixelBufferGetWidth(map), CVPixelBufferGetHeight(map), 0, &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture else { return nil }
        return CVMetalTextureGetTexture(cvTexture)
    }

    // MARK: - Frame

    /// Draws one frame. `walls` is the coplanar group of the selected wall, or empty to pass the
    /// camera through; `paint` is the illuminant-adapted linear reflectance of the chosen colour.
    func draw(frame: ARFrame,
              walls: [WallGeometry],
              openings: [OpeningGeometry] = [],
              paint: SIMD3<Float>,
              in view: MTKView,
              orientation: UIInterfaceOrientation) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let yTexture = texture(from: frame.capturedImage, plane: 0, format: .r8Unorm),
              let cbcrTexture = texture(from: frame.capturedImage, plane: 1, format: .rg8Unorm)
        else { return }

        ensureTargets(size: view.drawableSize)
        guard let maskTexture, let blurTexture, let meanTexture,
              let commandBuffer = queue.makeCommandBuffer() else { return }

        let viewport = SIMD2<Float>(Float(view.drawableSize.width), Float(view.drawableSize.height))
        let depth = depthTexture(from: frame)
        uniforms.viewportSize = viewport
        uniforms.bilateralStep = bilateralStep(depth: depth, viewport: viewport) * zoom
        uniforms.paintLinear = paint
        uniforms.detailGain = detailGain
        uniforms.occluderBand = occluderBounds.band
        uniforms.occluderRamp = occluderBounds.rampWidth
        uniforms.zoom = zoom
        uniforms.occluderRange = occluderBounds.rangeTolerance
        uniforms.meanWallLuma = meanWallLuma
        uniforms.meanWallRGB = meanWallRGB
        uniforms.cameraUVTransform = cameraUVTransform(frame: frame,
                                                       viewportSize: view.drawableSize,
                                                       orientation: orientation)

        // --- Pass A: mask ---
        let maskPass = MTLRenderPassDescriptor()
        maskPass.colorAttachments[0].texture = maskTexture
        maskPass.colorAttachments[0].loadAction = .clear
        maskPass.colorAttachments[0].storeAction = .store
        maskPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        if !walls.isEmpty, let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: maskPass) {
            let camera = frame.camera
            let projection = camera.projectionMatrix(for: orientation,
                                                     viewportSize: view.drawableSize,
                                                     zNear: 0.01, zFar: 50)
            let viewMatrix = camera.viewMatrix(for: orientation)
            let viewProjection = projection * viewMatrix

            var hasDepth: Int32 = depth == nil ? 0 : 1

            encoder.setRenderPipelineState(maskPipeline)
            encoder.setFragmentBytes(&hasDepth, length: MemoryLayout<Int32>.stride, index: 2)
            encoder.setFragmentTexture(yTexture, index: 0)
            encoder.setFragmentTexture(cbcrTexture, index: 1)
            // Never nil: an empty slot is what Metal API Validation aborts on.
            encoder.setFragmentTexture(depth ?? placeholderDepth, index: 2)

            for wall in walls {
                uniforms.modelViewProjection = viewProjection * wall.transform
                encoder.setVertexBuffer(wall.vertexBuffer, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<WallUniforms>.stride, index: 1)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WallUniforms>.stride, index: 1)
                encoder.drawIndexedPrimitives(type: .triangle,
                                              indexCount: wall.indexCount,
                                              indexType: .uint32,
                                              indexBuffer: wall.indexBuffer,
                                              indexBufferOffset: 0)
            }
            // --- Pass A2: subtract classified openings ---
            //
            // Before the blur, so a doorway cannot contaminate the wall's shading estimate.
            if !openings.isEmpty {
                encoder.setRenderPipelineState(openingPipeline)
                for opening in openings {
                    uniforms.modelViewProjection = viewProjection * opening.transform
                    encoder.setVertexBuffer(opening.vertexBuffer, offset: 0, index: 0)
                    encoder.setVertexBytes(&uniforms, length: MemoryLayout<WallUniforms>.stride, index: 1)
                    encoder.drawIndexedPrimitives(type: .triangle,
                                                  indexCount: opening.indexCount,
                                                  indexType: .uint32,
                                                  indexBuffer: opening.indexBuffer,
                                                  indexBufferOffset: 0)
                }
            }

            encoder.endEncoding()

            // --- Pass B: normalised-convolution blur, then mean for shading normalisation ---
            if let blur, let meanReduce {
                blur.encode(commandBuffer: commandBuffer,
                            sourceTexture: maskTexture,
                            destinationTexture: blurTexture)
                meanReduce.encode(commandBuffer: commandBuffer,
                                  sourceTexture: maskTexture,
                                  destinationTexture: meanTexture)
            }
        }

        // --- Pass C: composite ---
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) {
            encoder.setRenderPipelineState(compositePipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WallUniforms>.stride, index: 0)
            encoder.setFragmentTexture(yTexture, index: 0)
            encoder.setFragmentTexture(cbcrTexture, index: 1)
            encoder.setFragmentTexture(maskTexture, index: 2)
            encoder.setFragmentTexture(blurTexture, index: 3)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        // --- Optional: copy the drawable for a still ---
        //
        // Blitted into our own texture: by the time the handler runs the drawable may be recycled.
        var captureDestination: MTLTexture?
        if captureToken != servicedCaptureToken {
            // Marked serviced before the work is queued; the handler lands several frames later.
            servicedCaptureToken = captureToken
            let copy = captureTarget(matching: drawable.texture)
            if let copy, let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.copy(from: drawable.texture, to: copy)
                blit.endEncoding()
                captureDestination = copy
            }
        }

        // Handlers run on a Metal-owned thread, so each hops to the main actor to apply its value.
        let meanBox = TextureBox(meanTexture)
        commandBuffer.addCompletedHandler { [weak self] _ in
            guard let sample = WallRenderer.decodeMean(from: meanBox.texture) else { return }
            Task { @MainActor in self?.apply(sample) }
        }

        if let captureDestination, let deliver = onCapture {
            let captureBox = TextureBox(captureDestination)
            commandBuffer.addCompletedHandler { _ in
                let image = WallRenderer.image(from: captureBox.texture)
                Task { @MainActor in deliver(image) }
            }
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// A shared-storage texture matching the drawable, reused across captures.
    private func captureTarget(matching drawable: MTLTexture) -> MTLTexture? {
        if let existing = captureTexture,
           existing.width == drawable.width,
           existing.height == drawable.height,
           existing.pixelFormat == drawable.pixelFormat {
            return existing
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: drawable.pixelFormat,
            width: drawable.width,
            height: drawable.height,
            mipmapped: false
        )
        // Shared so the CPU can read it without a second staging copy.
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        captureTexture = device.makeTexture(descriptor: descriptor)
        return captureTexture
    }

    /// Turns a BGRA8 texture into a CGImage, tagged sRGB to match the layer.
    private nonisolated static func image(from texture: MTLTexture) -> CGImage? {
        let width = texture.width, height = texture.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.getBytes(base,
                             bytesPerRow: bytesPerRow,
                             from: MTLRegionMake2D(0, 0, width, height),
                             mipmapLevel: 0)
        }

        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        // Little-endian BGRA; alpha is meaningless here, so skip it.
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)

        return CGImage(width: width,
                       height: height,
                       bitsPerComponent: 8,
                       bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow,
                       space: colorSpace,
                       bitmapInfo: bitmapInfo,
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    /// One frame's mask-weighted mean, as a value that can cross actor boundaries.
    private struct MeanSample: Sendable {
        let luma: Float
        let rgb: SIMD3<Float>
    }

    /// Reads the 1x1 reduction: `meanGBA / meanR` is the mask-weighted average.
    private nonisolated static func decodeMean(from texture: MTLTexture) -> MeanSample? {
        var halfPixel = [UInt16](repeating: 0, count: 4)
        texture.getBytes(&halfPixel,
                         bytesPerRow: MemoryLayout<UInt16>.stride * 4,
                         from: MTLRegionMake2D(0, 0, 1, 1),
                         mipmapLevel: 0)
        let coverage = Float(float16: halfPixel[0])
        guard coverage > 1e-4 else { return nil }

        let meanRGB = SIMD3<Float>(Float(float16: halfPixel[1]),
                                   Float(float16: halfPixel[2]),
                                   Float(float16: halfPixel[3])) / coverage
        let mean = simd_dot(meanRGB, lumaWeights)
        guard mean.isFinite, mean > 1e-4, meanRGB.min() >= 0 else { return nil }
        return MeanSample(luma: mean, rgb: meanRGB)
    }

    /// Folds a new sample into the running means.
    private func apply(_ sample: MeanSample) {
        // Light temporal smoothing, so the wall does not flicker as new plane extent is found.
        meanWallLuma += (sample.luma - meanWallLuma) * 0.15
        meanWallRGB += (sample.rgb - meanWallRGB) * 0.15
    }

    /// Rec.709 luminance weights, matching the sRGB primaries used throughout the pipeline.
    private nonisolated static let lumaWeights = SIMD3<Float>(0.2126729, 0.7151522, 0.0721750)

    /// Maps fullscreen UVs onto the camera image for the current orientation.
    private func cameraUVTransform(frame: ARFrame,
                                   viewportSize: CGSize,
                                   orientation: UIInterfaceOrientation) -> simd_float3x3 {
        let transform = frame.displayTransform(for: orientation, viewportSize: viewportSize).inverted()
        return simd_float3x3(
            SIMD3<Float>(Float(transform.a), Float(transform.b), 0),
            SIMD3<Float>(Float(transform.c), Float(transform.d), 0),
            SIMD3<Float>(Float(transform.tx), Float(transform.ty), 1)
        )
    }
}

private extension Float {
    /// Decodes an IEEE 754 binary16 stored in a `UInt16`.
    init(float16 bits: UInt16) {
        self = Float(Float16(bitPattern: bits))
    }
}

/// Carries an `MTLTexture` into a GPU completion handler.
///
/// Sound here: the handler runs only after the command buffer completes, and only reads a
/// shared-storage texture.
private struct TextureBox: @unchecked Sendable {
    let texture: MTLTexture
    init(_ texture: MTLTexture) { self.texture = texture }
}
