import simd

/// A paint colour: an sRGB swatch for hue, and a measured LRV for lightness.
struct PaintColor: Identifiable, Hashable, Codable, Sendable {
    let id: String
    /// Display name, e.g. "Terracotta".
    let name: String
    /// Manufacturer code where there is one, empty otherwise.
    let code: String
    /// Published sRGB swatch, used for hue and saturation only.
    let hex: UInt32
    /// Published Light Reflectance Value, 0–100. Treated as authoritative for lightness.
    let lrv: Float
    /// Whether the user entered this colour. Drives the paid gate.
    var isCustom = false

    /// Linear-light reflectance in the sRGB primaries, with luminance rescaled to match ``lrv``.
    var linearReflectance: SIMD3<Float> {
        let encoded = SIMD3<Float>(
            Float((hex >> 16) & 0xFF) / 255.0,
            Float((hex >>  8) & 0xFF) / 255.0,
            Float( hex        & 0xFF) / 255.0
        )
        let linear = ColorScience.srgbToLinear(encoded)

        // Rec.709 luminance weights, matching the sRGB primaries' Y row.
        let swatchLuminance = dot(linear, SIMD3<Float>(0.2126729, 0.7151522, 0.0721750))
        let targetLuminance = lrv / 100.0
        guard swatchLuminance > 1e-5 else { return SIMD3(repeating: targetLuminance) }
        return linear * (targetLuminance / swatchLuminance)
    }

    /// The colour's XYZ tristimulus under a given scene illuminant.
    func adaptedReflectance(under illuminant: SIMD3<Float>) -> SIMD3<Float> {
        let xyz = ColorScience.srgbToXYZ * linearReflectance
        return xyz * (illuminant / ColorScience.d65)
    }
}

/// The colours the app ships with.
///
/// Each LRV is its own swatch's luminance, so ``PaintColor/linearReflectance`` scales by 1. For a
/// real manufacturer colour use the published LRV: the two diverge by 25-30% on deep colours.
enum PaintCatalog {

    static let all: [PaintColor] = [
        PaintColor(id: "soft-white",  name: "Soft White",  code: "", hex: 0xF2EFE7, lrv: 86.38),
        PaintColor(id: "powder-blue", name: "Powder Blue", code: "", hex: 0xA9C5D6, lrv: 53.22),
        PaintColor(id: "terracotta",  name: "Terracotta",  code: "", hex: 0xB26B45, lrv: 20.41)
    ]

    /// The colours offered in the swatch row.
    static let featured: [PaintColor] = all

    /// The colour selected at launch.
    static let `default` = all[0]
}
