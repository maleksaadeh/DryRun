import ARKit
import Metal
import simd

/// GPU-ready triangulation of a detected wall plane.
///
/// Built once per plane-geometry update rather than per frame. Because the mesh lives in the
/// anchor's local space and ARKit keeps the anchor pose world-locked, the mask stays stable as
/// the user moves — the property a per-frame neural mask cannot offer, and the reason a visibly
/// flickering repaint is not a failure mode of this design.
struct WallGeometry {
    let identifier: UUID
    let transform: simd_float4x4
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let indexCount: Int
    /// Plane area in square metres, used to prefer the largest candidate wall on an ambiguous tap.
    let area: Float

    /// Builds buffers from a plane anchor, or returns `nil` if the plane has no usable mesh yet.
    ///
    /// - Parameters:
    ///   - anchor: A plane anchor; the caller is responsible for checking it is wall-classified.
    ///   - device: Metal device used to allocate the buffers.
    /// How far the measured boundary is pushed outward, in metres.
    ///
    /// ARKit's plane polygon is reliably *smaller* than the wall. It is fitted from the interior
    /// and least confident exactly where paint needs to reach — inside corners, and the ceiling and
    /// floor junctions — so using it verbatim leaves an unpainted border along every wall edge.
    ///
    /// Dilating is safe here only because the fragment stage tests measured depth against the
    /// fitted plane: geometry pushed past the real wall lands on a surface at a different depth and
    /// is rejected there. So this widens what *may* be painted and depth decides what *is* —
    /// the same division of labour the opening test already relies on.
    ///
    /// 0.25 m covers the observed shortfall without reaching so far that a mis-fitted plane can
    /// cross a room. The residual is a few centimetres of bleed at an inside corner, where the
    /// adjoining wall's depth genuinely does agree with ours; that is the same order as the
    /// existing trim bleed and is documented rather than solved.
    static let boundaryMargin: Float = 0.25

    init?(anchor: ARPlaneAnchor, device: MTLDevice) {
        let geometry = anchor.geometry
        let vertices = Self.dilated(geometry.vertices, about: anchor.center)
        // ARKit hands back Int16 indices; the pipeline is declared uint32, so widen here rather
        // than adding a second index-type path to the renderer.
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
    }

    /// Pushes each boundary vertex away from the plane centre by `boundaryMargin`.
    ///
    /// Displaces by a fixed distance rather than scaling about the centre: scaling would move
    /// distant vertices further than near ones, stretching a long wall's ends far more than its
    /// middle, when the shortfall being corrected is roughly uniform along the boundary.
    ///
    /// ARKit plane vertices lie in local XZ with Y as the normal, so Y is left untouched — moving
    /// it would lift geometry off the plane and break the depth comparison that makes the
    /// dilation safe.
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
