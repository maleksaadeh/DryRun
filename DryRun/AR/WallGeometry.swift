import ARKit
import Metal
import simd

/// GPU-ready triangulation of a detected wall plane.
struct WallGeometry {
    let identifier: UUID
    let transform: simd_float4x4
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let indexCount: Int
    /// Plane area in square metres, used to prefer the largest candidate wall on an ambiguous tap.
    let area: Float
    /// The anchor's centre at the time of tessellation, which is what `dilated` measured from.
    let center: simd_float3

    /// How far the measured boundary is pushed outward, in metres.
    ///
    /// ARKit's plane polygon is reliably smaller than the wall, so using it verbatim leaves an
    /// unpainted border. Kept small: the push is radial from `anchor.center`, so a large margin
    /// turns every shift of that centre into a boundary that swings in every direction at once.
    /// The fragment stage's depth and planarity tests reject the overshoot.
    static let boundaryMargin: Float = 0.06

    /// Re-tessellation thresholds. ARKit re-fits a plane on nearly every frame; below these the
    /// change is jitter, and rebuilding on it makes the painted edge breathe.
    private static let positionTolerance: Float = 0.02   // metres
    private static let areaTolerance: Float = 0.03       // fraction
    private static let normalTolerance: Float = 0.9994   // cos 2 degrees

    init?(anchor: ARPlaneAnchor, device: MTLDevice) {
        let geometry = anchor.geometry
        let vertices = Self.dilated(geometry.vertices, about: anchor.center)
        // ARKit hands back Int16 indices; the pipeline is declared uint32.
        let indices = geometry.triangleIndices.map { UInt32($0) }
        guard !vertices.isEmpty, !indices.isEmpty else { return nil }

        guard let vertexBuffer = device.makeBuffer(
                bytes: vertices,
                length: MemoryLayout<simd_float3>.stride * vertices.count,
                options: .storageModeShared),
              let indexBuffer = device.makeBuffer(
                bytes: indices,
                length: MemoryLayout<UInt32>.stride * indices.count,
                options: .storageModeShared)
        else { return nil }

        self.identifier = anchor.identifier
        self.transform = anchor.transform
        self.vertexBuffer = vertexBuffer
        self.indexBuffer = indexBuffer
        self.indexCount = indices.count
        self.area = anchor.planeExtent.width * anchor.planeExtent.height
        self.center = anchor.center
    }

    /// Whether `anchor` has moved or grown little enough that this tessellation still stands.
    ///
    /// Bounded error, not zero error: the geometry can lag the anchor by up to the tolerances
    /// above, which is a far smaller artefact than rebuilding on every update produces.
    func matches(_ anchor: ARPlaneAnchor) -> Bool {
        guard simd_distance(center, anchor.center) <= Self.positionTolerance else { return false }

        let newArea = anchor.planeExtent.width * anchor.planeExtent.height
        guard area > 0, abs(newArea - area) / area <= Self.areaTolerance else { return false }

        guard simd_distance(Self.origin(of: transform),
                            Self.origin(of: anchor.transform)) <= Self.positionTolerance
        else { return false }

        return simd_dot(Self.normal(of: transform),
                        Self.normal(of: anchor.transform)) >= Self.normalTolerance
    }

    /// ARKit plane convention: the surface normal is the transform's Y axis.
    private static func normal(of transform: simd_float4x4) -> simd_float3 {
        simd_normalize(simd_float3(transform.columns.1.x,
                                   transform.columns.1.y,
                                   transform.columns.1.z))
    }

    private static func origin(of transform: simd_float4x4) -> simd_float3 {
        simd_float3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
    }

    /// Pushes each boundary vertex away from the plane centre by `boundaryMargin`.
    ///
    /// Plane vertices lie in local XZ, so Y is left untouched.
    private static func dilated(_ vertices: [simd_float3],
                                about center: simd_float3) -> [simd_float3] {
        vertices.map { vertex in
            let offset = SIMD2(vertex.x - center.x, vertex.z - center.z)
            let distance = simd_length(offset)
            guard distance > 1e-5 else { return vertex }
            let push = offset / distance * boundaryMargin
            return simd_float3(vertex.x + push.x, vertex.y, vertex.z + push.y)
        }
    }
}
