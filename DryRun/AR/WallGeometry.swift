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

    /// How far the measured boundary is pushed outward, in metres.
    ///
    /// ARKit's plane polygon is reliably smaller than the wall, so using it verbatim leaves an
    /// unpainted border. The fragment stage's depth test is what rejects the overshoot.
    static let boundaryMargin: Float = 0.25

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
