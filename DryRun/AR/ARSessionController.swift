import ARKit
import Metal
import simd

/// Owns the ARKit session and decides which plane is "the wall".
///
/// Wall discovery is entirely native: ARKit classifies detected vertical planes, and on LiDAR
/// hardware `sceneDepth` supplies the occlusion needed to keep furniture and door frames out of
/// the repaint. No segmentation model is loaded, which removes the model download, the sustained
/// Neural Engine cost, and any third-party runtime from the shipping dependency list.
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

    /// Whether openings are subtracted from the mask. Exposed so the effect can be A/B'd on
    /// device, which is the only way to judge whether the mesh classification is good enough to
    /// trust — it is coarse, and a false positive removes paint from real wall.
    @Published var excludesOpenings = true

    /// Camera image aspect ratio (width / height) as displayed in portrait.
    ///
    /// Published so the UI can work out how far it is worth zooming out: `displayTransform`
    /// aspect-*fills*, so a tall portrait viewport already crops the 4:3 frame horizontally, and
    /// the uncropped width is only reachable by zooming below 1.
    @Published private(set) var cameraAspect: Float?

    /// Why tracking is degraded, when it is.
    ///
    /// This is the signal that names the dark-wall problem outright. ARKit fits planes partly from
    /// visual feature points, and a dark, matte, evenly lit wall yields almost none — which
    /// surfaces here as `.limited(.insufficientFeatures)`. Without it, "0 walls" is
    /// indistinguishable from a bug in our own gate, which is why it is now on screen.
    @Published private(set) var trackingNote: String?

    /// When each mesh anchor was last converted, so a rebuild can be rate-limited per anchor.
    private var lastOpeningRebuild: [UUID: CFTimeInterval] = [:]

    /// Minimum gap between rebuilds of the same anchor.
    ///
    /// Mesh anchors update continuously and each conversion is a linear scan over every face, on
    /// the CPU, on the main thread. At ARKit's update rate that is real cost on a demo that already
    /// caps work for thermal reasons — and openings do not move, so refreshing one twice a second
    /// loses nothing.
    private static let openingRebuildInterval: CFTimeInterval = 0.5

    var selectedWall: WallGeometry? {
        selectedWallID.flatMap { walls[$0] }
    }

    /// Every wall plane lying on the same infinite plane as the selection, largest first.
    ///
    /// ARKit routinely represents one physical wall as several anchors — panning along a long wall
    /// grows a plane for a while and then starts a fresh one, and coplanar neighbours are merged
    /// only sometimes. Painting `selectedWall` alone therefore stops partway along a continuous
    /// wall, with the remainder left bare at an arbitrary seam.
    ///
    /// Grouping by the plane equation rather than by anchor identity makes the seam invisible: all
    /// the segments rasterise into one mask, so they also share one shading normalisation and one
    /// mean illuminant, which is what keeps the repaint continuous across the join.
    var selectedWallGroup: [WallGeometry] {
        guard let seed = selectedWall else { return [] }
        return walls.values
            .filter { Self.isCoplanar($0, with: seed) }
            .sorted { $0.area > $1.area }
    }

    /// Whether two wall planes describe the same physical surface.
    ///
    /// Tests the plane equation directly: normals pointing the same way, and origins lying on each
    /// other's plane. Lateral distance is deliberately *not* tested — two segments of one wall can
    /// be metres apart with a doorway between them and still be the same wall to paint.
    ///
    /// Facing is required to match rather than merely align, which is what keeps the far side of a
    /// thin partition out of the group: its normal is antiparallel, so it fails the first test
    /// before the ~6 cm offset tolerance ever comes into play.
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

    /// The anchor origin lies in the plane, so it defines the plane equation as well as the
    /// centre offset would.
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
        // No session at all on the simulator. `ARWorldTrackingConfiguration` is unsupported there,
        // and running one raises rather than failing quietly, so there is nothing to guard against
        // afterwards — the only safe thing is not to start. `DeviceCapability` still lets the
        // simulator reach this screen so the controls can be laid out; the render loop draws
        // nothing because `session.currentFrame` stays nil, which is the black behind them.
        status = "Simulator preview — no camera or wall tracking. The controls are live."
        return
        #else
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.vertical]
        configuration.environmentTexturing = .automatic

        // Scene reconstruction sharpens plane extents and, more importantly, supplies the
        // per-pixel depth the occlusion test needs. `DeviceCapability` has already established
        // both are available; these stay guarded because setting an unsupported option on the
        // configuration raises rather than being ignored.
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

        // Read once here rather than per frame: the format is fixed for the session, and
        // republishing at 60 Hz would churn every view observing this controller.
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
    /// Distinct from `start()` on purpose: that passes `[.resetTracking, .removeExistingAnchors]`,
    /// which is right at launch and wrong here. Coming back from the gallery to find every wall
    /// gone and the selection cleared would make browsing a saved still cost the user their setup.
    /// Re-running with no options lets ARKit relocalise against the map it still holds.
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
    /// Raycasts against existing plane *geometry* rather than infinite planes, so a tap past the
    /// edge of a detected wall does not silently select it.
    ///
    /// - Parameters:
    ///   - point: Tap location in view coordinates.
    ///   - view: The view the tap occurred in, used to normalise the point.
    ///   - orientation: Current interface orientation.
    func selectWall(at point: CGPoint, viewportSize size: CGSize, orientation: UIInterfaceOrientation) {
        guard let frame = session.currentFrame else {
            status = "No camera frame yet."
            return
        }

        guard size.width > 0, size.height > 0 else { return }

        // `ARFrame.raycastQuery` expects normalised *captured-image* coordinates, not view
        // coordinates. The display transform is what maps between them; skipping this inversion
        // makes taps land in the wrong place in every orientation except by coincidence.
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

        // Fall back to the largest known wall: during the first seconds of a session the plane
        // mesh often lags the visible surface, and failing a tap outright reads as a broken app.
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
            guard let geometry = WallGeometry(anchor: plane, device: device) else { continue }
            walls[plane.identifier] = geometry
        }
    }

    /// Harvests door and window faces from any mesh anchors in the batch.
    ///
    /// Anchors yielding no openings are recorded in `lastOpeningRebuild` as well, so a mesh full of
    /// plain wall is not rescanned on every single update just because it produced nothing.
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
    /// Accepts unclassified planes, which an earlier revision rejected. That rejection was
    /// guarding against painting floors and ceilings, but `planeDetection` is `[.vertical]`, so
    /// no horizontal plane is ever detected in the first place — the geometry constraint already
    /// does that job, and the classification gate was only costing us walls.
    ///
    /// And it cost them precisely where they are hardest to get: classification leans on visual
    /// evidence, so a dark, matte or evenly lit wall is exactly the case that stalls at
    /// `.none(.undetermined)` or gives up at `.none(.unknown)`. Refusing those meant the app
    /// detected a perfectly good dark wall and then discarded it.
    ///
    /// Doors and windows stay rejected. They are vertical, so geometry cannot exclude them, and
    /// they are the one affirmative classification we actively do not want to paint over.
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
        // Capture the plane being selected before it leaves the dictionary, so a merge can be
        // followed rather than simply losing the wall.
        let departing = anchors.first { $0.identifier == selectedWallID }
            .flatMap { walls[$0.identifier] }

        for anchor in anchors {
            walls.removeValue(forKey: anchor.identifier)
            openings.removeValue(forKey: anchor.identifier)
            lastOpeningRebuild.removeValue(forKey: anchor.identifier)
        }

        guard let departing else { return }

        // ARKit removes an anchor when it merges into a neighbour, so the wall usually still
        // exists under a different identity. Re-selecting the largest coplanar survivor keeps the
        // paint on screen; dropping the selection instead made the wall flicker off mid-pan, which
        // looked like a tracking failure rather than the bookkeeping event it is.
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
                // The dark-wall case. Worth naming rather than reporting "limited", because the
                // remedy is the room — more light, or a textured surface in view — not a retry.
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
