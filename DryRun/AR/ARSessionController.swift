import ARKit
import Metal
import simd

/// Owns the ARKit session and decides which plane is "the wall".
@MainActor
final class ARSessionController: NSObject, ObservableObject {

    let session = ARSession()
    private let device: MTLDevice

    /// Wall-classified planes seen so far, keyed by anchor identity.
    @Published private(set) var walls: [UUID: WallGeometry] = [:]
    @Published private(set) var selectedWallID: UUID?
    @Published private(set) var status = "Point at a wall and pan slowly."
    /// True when the device supplies scene depth, which enables occlusion.
    @Published private(set) var hasSceneDepth = false
    /// Door and window faces harvested from the reconstruction mesh, keyed by anchor.
    @Published private(set) var openings: [UUID: OpeningGeometry] = [:]

    /// Whether openings are subtracted from the mask.
    @Published var excludesOpenings = true

    /// Camera image aspect ratio (width / height) as displayed in portrait.
    @Published private(set) var cameraAspect: Float?

    /// Why tracking is degraded, when it is.
    @Published private(set) var trackingNote: String?

    /// When each mesh anchor was last converted, so a rebuild can be rate-limited per anchor.
    private var lastOpeningRebuild: [UUID: CFTimeInterval] = [:]
    /// Minimum gap between rebuilds of the same anchor.
    private static let openingRebuildInterval: CFTimeInterval = 0.5

    var selectedWall: WallGeometry? {
        selectedWallID.flatMap { walls[$0] }
    }

    /// Every wall plane lying on the same infinite plane as the selection, largest first.
    ///
    /// ARKit routinely splits one physical wall across several anchors.
    var selectedWallGroup: [WallGeometry] {
        guard let seed = selectedWall else { return [] }
        return walls.values
            .filter { Self.isCoplanar($0, with: seed) }
            .sorted { $0.area > $1.area }
    }

    /// Whether two wall planes describe the same physical surface.
    ///
    /// Lateral distance is deliberately not tested: two segments of one wall can be metres apart.
    static func isCoplanar(_ candidate: WallGeometry, with seed: WallGeometry) -> Bool {
        let seedNormal = normal(of: seed.transform)
        guard simd_dot(seedNormal, normal(of: candidate.transform)) > 0.985 else { return false }
        let seedOrigin = origin(of: seed.transform)
        let offset = simd_dot(origin(of: candidate.transform) - seedOrigin, seedNormal)
        return abs(offset) < 0.06
    }

    /// ARKit plane convention: the surface normal is the transform's Y axis.
    private static func normal(of transform: simd_float4x4) -> SIMD3<Float> {
        simd_normalize(SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z))
    }

    /// The anchor origin lies in the plane, so it defines the plane equation.
    private static func origin(of transform: simd_float4x4) -> SIMD3<Float> {
        SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
    }

    init(device: MTLDevice) {
        self.device = device
        super.init()
        session.delegateQueue = .main
        session.delegate = self
    }

    func start() {
        #if targetEnvironment(simulator)
        // `ARWorldTrackingConfiguration` is unsupported on the simulator and running one raises.
        status = "Simulator preview — no camera or wall tracking. The controls are live."
        return
        #else
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.vertical]
        configuration.environmentTexturing = .automatic
        // Guarded because setting an unsupported option raises.
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            configuration.sceneReconstruction = .meshWithClassification
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
            hasSceneDepth = true
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
            hasSceneDepth = true
        }

        // Read once: the format is fixed for the session.
        let resolution = configuration.videoFormat.imageResolution
        if resolution.width > 0, resolution.height > 0 {
            // The capture is landscape-native, so portrait width/height is the inverse.
            cameraAspect = Float(resolution.height / resolution.width)
        }

        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        #endif
    }

    func pause() {
        session.pause()
    }

    /// Restarts a paused session without discarding what it already knows.
    ///
    /// Distinct from `start()`, which resets tracking and drops every anchor.
    func resume() {
        guard let configuration = session.configuration else {
            start()
            return
        }
        session.run(configuration)
        status = "Resuming — pan slowly to relocalise."
    }

    /// Selects the wall under a tap.
    ///
    /// Raycasts against existing plane *geometry*, so a tap past the edge of a detected wall does
    /// not silently select it.
    func selectWall(at point: CGPoint, viewportSize size: CGSize, orientation: UIInterfaceOrientation) {
        guard let frame = session.currentFrame else {
            status = "No camera frame yet."
            return
        }

        guard size.width > 0, size.height > 0 else { return }

        // `raycastQuery` expects normalised captured-image coordinates, not view coordinates.
        let normalised = CGPoint(x: point.x / size.width, y: point.y / size.height)
        let toImageSpace = frame.displayTransform(for: orientation, viewportSize: size).inverted()
        let imagePoint = normalised.applying(toImageSpace)

        let query = frame.raycastQuery(from: imagePoint,
                                       allowing: .existingPlaneGeometry,
                                       alignment: .vertical)

        if let hit = session.raycast(query).first,
           let anchor = hit.anchor as? ARPlaneAnchor,
           walls[anchor.identifier] != nil {
            selectedWallID = anchor.identifier
            status = "Wall selected."
            return
        }

        // The plane mesh lags the visible surface early on, and failing a tap reads as broken.
        if let largest = walls.values.max(by: { $0.area < $1.area }) {
            selectedWallID = largest.identifier
            status = "No wall exactly there — selected the largest detected wall."
        } else {
            status = "No wall detected yet. Pan slowly across the wall."
        }
    }

    func clearSelection() {
        selectedWallID = nil
        status = "Tap a wall to select it."
    }

    private func ingest(_ anchors: [ARAnchor]) {
        ingestMeshes(anchors)
        for anchor in anchors {
            guard let plane = anchor as? ARPlaneAnchor else { continue }
            guard Self.isPaintable(plane) else {
                walls.removeValue(forKey: plane.identifier)
                continue
            }
            // ARKit re-fits and re-tessellates on nearly every update. Reusing the geometry until
            // the fit actually moves keeps the painted boundary still, and saves two buffer
            // allocations per anchor per frame.
            if let existing = walls[plane.identifier], existing.matches(plane) { continue }
            guard let geometry = WallGeometry(anchor: plane, device: device) else { continue }
            walls[plane.identifier] = geometry
        }
    }

    /// Harvests door and window faces from any mesh anchors in the batch.
    private func ingestMeshes(_ anchors: [ARAnchor]) {
        let now = CACurrentMediaTime()
        for anchor in anchors {
            guard let mesh = anchor as? ARMeshAnchor else { continue }
            if let last = lastOpeningRebuild[mesh.identifier],
               now - last < Self.openingRebuildInterval {
                continue
            }
            lastOpeningRebuild[mesh.identifier] = now

            if let geometry = OpeningGeometry(anchor: mesh, device: device) {
                openings[mesh.identifier] = geometry
            } else {
                openings.removeValue(forKey: mesh.identifier)
            }
        }
    }

    /// Whether a detected plane should be offered as a paintable wall.
    ///
    /// Unclassified planes are accepted: classification stalls at `.none` on exactly the dark,
    /// matte, evenly lit walls that are hardest to detect. Doors and windows stay rejected.
    static func isPaintable(_ plane: ARPlaneAnchor) -> Bool {
        switch plane.classification {
        case .wall, .none:
            return true
        case .door, .window:
            return false
        default:
            // Table, seat, or any class Apple adds later: not a wall.
            return false
        }
    }
}

extension ARSessionController: @preconcurrency ARSessionDelegate {

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        ingest(anchors)
        if selectedWallID == nil, !walls.isEmpty {
            status = "Wall found. Tap it to paint."
        }
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        ingest(anchors)
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        // Capture the selected plane before it leaves the dictionary, so a merge can be followed.
        let departing = anchors.first { $0.identifier == selectedWallID }
            .flatMap { walls[$0.identifier] }

        for anchor in anchors {
            walls.removeValue(forKey: anchor.identifier)
            openings.removeValue(forKey: anchor.identifier)
            lastOpeningRebuild.removeValue(forKey: anchor.identifier)
        }

        guard let departing else { return }

        // ARKit removes an anchor when it merges into a neighbour, so the wall usually survives.
        if let heir = walls.values
            .filter({ Self.isCoplanar($0, with: departing) })
            .max(by: { $0.area < $1.area }) {
            selectedWallID = heir.identifier
        } else {
            selectedWallID = nil
            status = "Lost the wall — tap it again."
        }
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        switch camera.trackingState {
        case .normal:
            trackingNote = nil
        case .notAvailable:
            trackingNote = "tracking unavailable"
        case .limited(let reason):
            switch reason {
            case .insufficientFeatures:
                trackingNote = "too few visual features — add light or pan across a textured area"
            case .initializing:      trackingNote = "initialising — pan slowly"
            case .excessiveMotion:   trackingNote = "moving too fast"
            case .relocalizing:      trackingNote = "relocalising"
            @unknown default:        trackingNote = "tracking limited"
            }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        status = "AR session failed: \(error.localizedDescription)"
    }

    func sessionWasInterrupted(_ session: ARSession) {
        status = "Session interrupted."
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        status = "Resuming — pan slowly to relocalise."
        start()
    }
}
