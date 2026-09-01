import simd

/// Colorimetry for rendering manufacturer paint colors under measured scene illuminants.
///
/// The pipeline works in **linear light** throughout. Camera pixels arrive gamma-encoded in a
/// device RGB space; paint colors are published as sRGB hex plus an LRV (Light Reflectance
/// Value). Neither is directly usable for relighting, so everything is converted to CIE XYZ,
/// adapted to the estimated scene illuminant, and only re-encoded at the final display step.
///
/// - Important: Every matrix here is row-major and expects **column vectors** (`M * v`).
///   `simd_float3x3` initializers take *columns*, so each literal below is transposed relative
///   to how the matrix is conventionally written.
enum ColorScience {

    // MARK: - Transfer functions

    /// Decodes an sRGB-encoded component to linear light.
    ///
    /// Uses the exact piecewise IEC 61966-2-1 curve rather than a 2.2 power approximation —
    /// the linear toe matters for dark walls, which is precisely the case this app is built for.
    static func srgbToLinear(_ c: Float) -> Float {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// Encodes a linear-light component to sRGB.
    static func linearToSRGB(_ c: Float) -> Float {
        c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1.0 / 2.4) - 0.055
    }

    static func srgbToLinear(_ c: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(srgbToLinear(c.x), srgbToLinear(c.y), srgbToLinear(c.z))
    }

    // MARK: - Primaries

    /// Linear sRGB (D65) to CIE XYZ.
    static let srgbToXYZ = simd_float3x3(columns: (
        SIMD3<Float>(0.4124564, 0.2126729, 0.0193339),
        SIMD3<Float>(0.3575761, 0.7151522, 0.1191920),
        SIMD3<Float>(0.1804375, 0.0721750, 0.9503041)
    ))

    /// CIE XYZ to linear sRGB (D65) — the inverse of ``srgbToXYZ``.
    ///
    /// The working space is sRGB rather than Display P3 on purpose. ARKit's captured frames
    /// arrive in Rec.709 primaries, so compositing them into a P3 target without converting
    /// would desaturate the untouched camera passthrough. Architectural paint is low-chroma and
    /// sits comfortably inside sRGB, so the gamut cost is near zero. Moving the whole pipeline
    /// to P3 — including a Rec.709 to P3 step on the camera texture — is the correct upgrade
    /// once saturated accent colours enter the catalogue.
    static let xyzToSRGB = simd_float3x3(columns: (
        SIMD3<Float>( 3.2404542, -0.9692660,  0.0556434),
        SIMD3<Float>(-1.5371385,  1.8760108, -0.2040259),
        SIMD3<Float>(-0.4985314,  0.0415560,  1.0572252)
    ))

    /// CIE XYZ to linear Display P3 (D65). Retained for the P3 upgrade path described above.
    static let xyzToDisplayP3 = simd_float3x3(columns: (
        SIMD3<Float>( 2.4934969, -0.8294890,  0.0358458),
        SIMD3<Float>(-0.9313836,  1.7626641, -0.0761724),
        SIMD3<Float>(-0.4027108,  0.0236247,  0.9568845)
    ))

    // MARK: - Illuminant estimation

    /// Chromaticity of the Planckian radiator at `kelvin`, via the Kim et al. cubic fit.
    ///
    /// ARKit reports scene lighting as a correlated colour temperature, which is a point on
    /// this locus. Valid over 1667K–25000K; inputs are clamped to that range.
    ///
    /// - Parameter kelvin: Correlated colour temperature.
    /// - Returns: CIE 1931 `xy` chromaticity.
    static func planckianChromaticity(kelvin: Float) -> SIMD2<Float> {
        let t = min(max(kelvin, 1667), 25000)
        let t2 = t * t, t3 = t2 * t

        let x: Float = t <= 4000
            ? -0.2661239e9 / t3 - 0.2343589e6 / t2 + 0.8776956e3 / t + 0.179910
            : -3.0258469e9 / t3 + 2.1070379e6 / t2 + 0.2226347e3 / t + 0.240390

        let x2 = x * x, x3 = x2 * x
        let y: Float
        if t <= 2222 {
            y = -1.1063814 * x3 - 1.34811020 * x2 + 2.18555832 * x - 0.20219683
        } else if t <= 4000 {
            y = -0.9549476 * x3 - 1.37418593 * x2 + 2.09137015 * x - 0.16748867
        } else {
            y = 3.0817580 * x3 - 5.87338670 * x2 + 3.75112997 * x - 0.37001483
        }
        return SIMD2(x, y)
    }

    /// Converts an `xy` chromaticity to an XYZ white point normalised to Y = 1.
    static func whitePoint(xy: SIMD2<Float>) -> SIMD3<Float> {
        guard xy.y > 1e-6 else { return SIMD3(0.9504, 1.0, 1.0888) } // D65 fallback
        return SIMD3(xy.x / xy.y, 1.0, (1.0 - xy.x - xy.y) / xy.y)
    }

    static func whitePoint(kelvin: Float) -> SIMD3<Float> {
        whitePoint(xy: planckianChromaticity(kelvin: kelvin))
    }

    static let d65 = SIMD3<Float>(0.9504, 1.0, 1.0888)

    // MARK: - Chromatic adaptation

    /// Bradford cone response — the standard basis for von Kries adaptation.
    static let bradford = simd_float3x3(columns: (
        SIMD3<Float>( 0.8951, -0.7502,  0.0389),
        SIMD3<Float>( 0.2664,  1.7135, -0.0685),
        SIMD3<Float>(-0.1614,  0.0367,  1.0296)
    ))

    static let bradfordInverse = simd_float3x3(columns: (
        SIMD3<Float>( 0.9869929,  0.4323053, -0.0085287),
        SIMD3<Float>(-0.1470543,  0.5183603,  0.0400428),
        SIMD3<Float>( 0.1599627,  0.0492912,  0.9684867)
    ))

    /// Builds the XYZ→XYZ matrix adapting colours from `source` white to `destination` white.
    ///
    /// This is what lets a paint chip specified under D65 be rendered as it would actually
    /// appear under 2700K incandescent — a lamp-lit room at night, which is when most people
    /// end up looking at a wall and wondering.
    ///
    /// - Parameters:
    ///   - source: XYZ white point the colour is currently relative to.
    ///   - destination: XYZ white point to adapt into.
    /// - Returns: A 3x3 adaptation matrix operating on XYZ column vectors.
    static func adaptation(from source: SIMD3<Float>, to destination: SIMD3<Float>) -> simd_float3x3 {
        let srcCone = bradford * source
        let dstCone = bradford * destination
        // Guard against a degenerate white point producing a division by zero.
        let ratio = SIMD3<Float>(
            srcCone.x.magnitude > 1e-6 ? dstCone.x / srcCone.x : 1,
            srcCone.y.magnitude > 1e-6 ? dstCone.y / srcCone.y : 1,
            srcCone.z.magnitude > 1e-6 ? dstCone.z / srcCone.z : 1
        )
        let scale = simd_float3x3(diagonal: ratio)
        return bradfordInverse * scale * bradford
    }
}
