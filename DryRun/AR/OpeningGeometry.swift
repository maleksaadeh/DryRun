import ARKit
import Metal
import simd

/// Door and window faces lifted out of a LiDAR scene-reconstruction mesh.
///
/// A closed door sits in the wall plane, so the depth test cannot see it.
struct OpeningGeometry {

    /// Faces classified as door or window. Everything else is discarded.
    static let excludedClassifications: Set<UInt8> = [
        UInt8(ARMeshClassification.door.rawValue),
        UInt8(ARMeshClassification.window.rawValue)
    ]

    let identifier: UUID
    let transform: simd_float4x4
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let indexCount: Int

    /// Builds buffers for the door and window faces of one mesh anchor, or `nil` if it has none.
    init?(anchor: ARMeshAnchor, device: MTLDevice) {
        let geometry = anchor.geometry
        guard let classification = geometry.classification else { return nil }

        let faces = geometry.faces
        guard faces.indexCountPerPrimitive == 3 else { return nil }

        // Classification is one byte per face, indexed by face number rather than by vertex.
        let classes = classification.buffer.contents()
            .advanced(by: classification.offset)
            .assumingMemoryBound(to: UInt8.self)

        let indices = faces.buffer.contents()
        let bytesPerIndex = faces.bytesPerIndex

        var kept: [UInt32] = []
        kept.reserveCapacity(faces.count / 8)

        for face in 0..<faces.count {
            let category = classes[face * classification.stride]
            guard Self.excludedClassifications.contains(category) else { continue }
            for corner in 0..<3 {
                let slot = face * 3 + corner
                // Width is declared per geometry rather than fixed, so it is read, not assumed.
                let value: UInt32
                switch bytesPerIndex {
                case 2:
                    value = UInt32(indices.advanced(by: slot * 2)
                        .assumingMemoryBound(to: UInt16.self).pointee)
                case 4:
                    value = indices.advanced(by: slot * 4)
                        .assumingMemoryBound(to: UInt32.self).pointee
                default:
                    return nil
                }
                kept.append(value)
            }
        }

        guard !kept.isEmpty else { return nil }

        let vertices = geometry.vertices
        guard vertices.format == .float3 else { return nil }

        // ARKit may recycle the vertex buffer once the anchor updates, so it is copied.
        var positions = [simd_float3](repeating: .zero, count: vertices.count)
        let base = vertices.buffer.contents().advanced(by: vertices.offset)
        for i in 0..<vertices.count {
            positions[i] = base.advanced(by: i * vertices.stride)
                .assumingMemoryBound(to: simd_float3.self).pointee
        }

        guard let vertexBuffer = device.makeBuffer(
                bytes: positions,
                length: MemoryLayout<simd_float3>.stride * positions.count,
                options: .storageModeShared),
              let indexBuffer = device.makeBuffer(
                bytes: kept,
                length: MemoryLayout<UInt32>.stride * kept.count,
                options: .storageModeShared)
        else { return nil }

        self.identifier = anchor.identifier
        self.transform = anchor.transform
        self.vertexBuffer = vertexBuffer
        self.indexBuffer = indexBuffer
        self.indexCount = kept.count
    }
}
