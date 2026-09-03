import simd

/// Colorimetry for rendering paint colors under measured scene illuminants, in linear light
/// throughout: sRGB hex plus LRV in, CIE XYZ and an illuminant adaptation between, sRGB out.
///
/// - Important: every matrix is written for column vectors (`M * v`), and `simd_float3x3` takes
///   *columns*, so each literal below is transposed relative to the conventional form.
enum ColorScience {

    // MARK: - Transfer functions

    /// Decodes an sRGB-encoded component to linear light.
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
    static let xyzToSRGB = simd_float3x3(columns: (
        SIMD3<Float>( 3.2404542, -0.9692660,  0.0556434),
        SIMD3<Float>(-1.5371385,  1.8760108, -0.2040259),
        SIMD3<Float>(-0.4985314,  0.0415560,  1.0572252)
    ))

    /// CIE XYZ to linear Display P3 (D65). Unused; the pipeline works in sRGB.
    static let xyzToDisplayP3 = simd_float3x3(columns: (
        SIMD3<Float>( 2.4934969, -0.8294890,  0.0358458),
        SIMD3<Float>(-0.9313836,  1.7626641, -0.0761724),
        SIMD3<Float>(-0.4027108,  0.0236247,  0.9568845)
    ))

    // MARK: - Illuminant estimation

    /// Chromaticity of the Planckian radiator at `kelvin`, via the Kim et al. cubic fit.
    /// Valid over 1667K-25000K; inputs are clamped.
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

    /// Builds the XYZ->XYZ matrix adapting colours from `source` white to `destination` white.
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
