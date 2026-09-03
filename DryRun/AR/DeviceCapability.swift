import ARKit
import Metal

/// What this iPhone can and cannot do, decided once at launch. There is no
/// `UIRequiredDeviceCapabilities` value for LiDAR, so this is the only enforcement.
enum DeviceCapability {

    enum Verdict: Equatable {
        case supported
        /// No world tracking: an older iPhone, or the simulator.
        case noWorldTracking
        /// World tracking, but no depth sensor — every non-Pro iPhone.
        case noLiDAR
        /// No Metal device. Should be unreachable on hardware that cleared the other two.
        case noMetal

        /// Whether the app cannot start at all, as opposed to starting and working badly.
        var isFatal: Bool {
            switch self {
            case .supported, .noLiDAR:       false
            case .noWorldTracking, .noMetal: true
            }
        }
    }

    static func evaluate() -> Verdict {
        #if targetEnvironment(simulator)
        // The simulator has no camera or tracking; let it through so the UI can be reviewed.
        return .supported
        #else
        guard ARWorldTrackingConfiguration.isSupported else { return .noWorldTracking }

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
