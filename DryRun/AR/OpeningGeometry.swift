import ARKit
import Metal
import simd

/// Door and window faces lifted out of a LiDAR scene-reconstruction mesh.
///
/// The session already runs `.meshWithClassification`, the most expensive reconstruction mode,
/// because it classifies the reconstructed geometry as well as building it. This is what consumes
/// that classification — without it the app would be paying for semantics it never read.
///
/// Scoped deliberately to *semantics*, never geometry. `ARMeshAnchor` is not used as a source of
/// wall geometry: it is coarse, it lags plane detection, and it would mean a second mesh path
/// competing with the plane anchors. None of that applies to using it as a lookup for "is this bit
/// of wall actually a door", which is a question plane anchors cannot answer at all — a closed door
/// flush with the wall sits *in* the plane, so the depth test cannot see it.
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
    ///
    /// Returning `nil` for the common case matters: most anchors in a room contain no opening at
    /// all, and the render loop should not pay for an empty draw call per anchor per frame.
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
                // ARKit documents this as UInt32 in practice, but the width is declared per
                // geometry rather than fixed, so it is read from `bytesPerIndex` instead of
                // assumed. Guessing wrong here would silently produce garbage triangles.
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

        // The vertex buffer is shared with ARKit and may be recycled once the anchor updates, so
        // it is copied rather than retained. Indices are already a local array.
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
