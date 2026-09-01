import ARKit
import Metal

/// Whether this iPhone can run the app at all, decided once at launch.
///
/// The app requires the LiDAR scanner, and that requirement cannot be declared in `Info.plist`.
/// `UIRequiredDeviceCapabilities` has no value for LiDAR, depth sensing or scene reconstruction —
/// Apple's DTS answer to this exact question is "there is no UIRequiredDeviceCapabilities key that
/// would restrict your app only to LiDAR devices", and their recommendation is a runtime check.
/// `arkit`, which the target does declare, is satisfied by every iPhone since the XS.
///
/// A `lidar` string in that array is a circulating suggestion that does not work. Nothing validates
/// the key locally, so it builds and installs and silently filters nothing — which is worse than
/// having no gate, because it looks like one.
///
/// Requiring depth rather than degrading without it is a deliberate reversal of how the renderer
/// was originally written. Without it there is no way to tell wall from television, from door
/// frame, from the person standing in front of it: an ARKit plane anchor is a filled polygon over
/// the whole wall extent and never has holes cut in it. The plane-only fallback therefore does not
/// produce a worse preview, it produces paint spread over the furniture.
enum DeviceCapability {

    /// Why the device was refused, or that it was not.
    enum Verdict: Equatable {
        case supported
        /// No world tracking: an older iPhone, or the simulator.
        case noWorldTracking
        /// World tracking, but no depth sensor — every non-Pro iPhone.
        case noLiDAR
        /// No Metal device. Should be unreachable on hardware that cleared the other two.
        case noMetal
    }

    /// Evaluates the device once.
    ///
    /// Order matters. The simulator fails `isSupported` *and* reports no scene reconstruction, so
    /// world tracking is tested first — otherwise a simulator run would be told it needs a Pro
    /// iPhone, which is true but not the useful half of the problem.
    static func evaluate() -> Verdict {
        #if targetEnvironment(simulator)
        // Let the simulator through so the screens can be laid out and reviewed without a device.
        //
        // It can never satisfy the real requirement — no camera, no world tracking, no LiDAR — so
        // what you get is the control surface over a black drawable: the render loop skips any
        // frame it does not have, and ARKit is never started at all (see `ARSessionController`).
        // Colours, zoom, the swatch row and the gallery are all live; the wall is not.
        //
        // Scoped to the simulator rather than to DEBUG on purpose. Simulator code is not present
        // in a device build at all, so this bypass cannot reach a shipped app or a non-Pro iPhone
        // even by accident, which a `#if DEBUG` gate could.
        return .supported
        #else
        guard ARWorldTrackingConfiguration.isSupported else { return .noWorldTracking }

        // Both halves of the LiDAR dependency, tested separately because they are separate
        // features here: mesh classification is what finds doors and windows, scene depth is what
        // keeps objects standing in front of the wall from being painted. Neither is optional.
        let hasMeshClassification =
            ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
        let hasSceneDepth =
            ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth)
            || ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        guard hasMeshClassification, hasSceneDepth else { return .noLiDAR }

        guard MTLCreateSystemDefaultDevice() != nil else { return .noMetal }

        return .supported
        #endif
    }
}
