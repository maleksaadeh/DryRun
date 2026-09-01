import simd

/// A manufacturer paint colour, stored as spectral-surrogate reflectance data.
///
/// Manufacturers publish two things per colour: an sRGB swatch value intended for screens, and
/// an **LRV** (Light Reflectance Value) measured off the physical drawdown. These disagree more
/// often than not — the swatch is chosen to look right in a browser, the LRV is instrument-
/// measured. Where they conflict this type trusts the LRV, because the acceptance test in the
/// RFP is against the physical sample, not against the website swatch.
///
/// - Note: The hex values below are approximations for demo purposes. Shipping this requires
///   the licensed palette data — and ideally spectral measurements of the actual peel-and-stick
///   stock, which would remove the metamerism error described in ``adaptedReflectance(under:)``.
struct PaintColor: Identifiable, Hashable, Sendable {
    let id: String
    /// Manufacturer name, e.g. "Hale Navy".
    let name: String
    /// Manufacturer code, e.g. "HC-154".
    let code: String
    /// Published sRGB swatch, used for hue and saturation only.
    let hex: UInt32
    /// Published Light Reflectance Value, 0–100. Treated as authoritative for lightness.
    let lrv: Float

    /// Linear-light reflectance in the sRGB primaries, with luminance rescaled to match ``lrv``.
    ///
    /// Takes the chromaticity implied by ``hex`` but renormalises so the colour's luminance
    /// equals the measured LRV. This is what makes a light-over-dark render land correctly:
    /// getting Chantilly Lace's *lightness* wrong by 8 LRV points is instantly visible against
    /// the physical sample, whereas a small hue error is not.
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

    /// The colour's XYZ tristimulus as it would appear under a given scene illuminant.
    ///
    /// Reflectance is illuminant-independent; appearance is not. Multiplying reflectance by the
    /// illuminant's white point approximates the reflected stimulus.
    ///
    /// - Parameter illuminant: XYZ white point of the scene light, normalised to Y = 1.
    /// - Returns: XYZ of the painted surface under that illuminant.
    /// - Note: This is an RGB-space approximation of a spectral product. Under narrowband
    ///   sources (LED, sodium) it will drift, because two colours matching under D65 need not
    ///   match under a spiky spectrum — metamerism. Spectral data for the sample stock is the
    ///   only real fix, and is a stated risk rather than an oversight.
    func adaptedReflectance(under illuminant: SIMD3<Float>) -> SIMD3<Float> {
        let xyz = ColorScience.srgbToXYZ * linearReflectance
        return xyz * (illuminant / ColorScience.d65)
    }
}

/// Demo subset of the Benjamin Moore palette, chosen to exercise the RFP's stated edge cases.
///
/// ## Adding a colour
///
/// One entry, appended to `warmEstimates` (or `published` if the LRV is a real measured figure):
///
/// ```swift
/// PaintColor(id: "AF-290", name: "Marigold", code: "AF-290", hex: 0xE0A94F, lrv: 45.0),
/// ```
///
/// - `id` — any unique string. The brand code is the convention here.
/// - `name`, `code` — shown under the swatch and stored with any capture taken.
/// - `hex` — the published sRGB swatch, as an integer literal (`0xRRGGBB`).
/// - `lrv` — Light Reflectance Value, 0–100, from the manufacturer's own data.
///
/// Files sit in a synchronized group, so nothing needs registering in the project; the swatch row
/// picks the colour up on the next build.
///
/// ### Why LRV is not optional
///
/// `linearReflectance` keeps only the *chromaticity* of `hex` and renormalises its luminance to
/// match `lrv`. The swatch decides the hue, LRV decides the lightness. Supplying a wrong LRV gives
/// the right colour at the wrong lightness — the one error this renderer exists to avoid, since
/// acceptance is judged against a physical sample.
///
/// LRV is published on the manufacturer's colour page (Benjamin Moore and Sherwin-Williams both
/// list it per colour) and printed on fan-deck chips.
///
/// ### If you only have a hex
///
/// How much that costs depends on the colour, measured against the `published` set above:
///
/// | Colour | Swatch luminance vs stated LRV |
/// |---|---|
/// | Light / low-saturation (LRV > 50) | within ~2–5% — deriving from hex is fine |
/// | Dark / saturated (LRV < 25) | swatch runs **25–30% too dark** |
///
/// Van Deusen Blue reads 10.0 from its swatch against a measured 12.94, and Hale Navy 6.97 against
/// 8.85. So for a pale colour, `lrv` set to the swatch's own luminance is a fair approximation; for
/// a deep or saturated one it will visibly misrepresent the paint, and the real figure is worth
/// looking up before showing it to anyone.
///
/// Keep guessed values in `warmEstimates`, not `published`. The split is what lets a reader tell
/// which colours can support an accuracy claim.
enum PaintCatalog {

    /// Colours spanning the full LRV range. The pairing that matters for acceptance is applying
    /// a high-LRV colour (Chantilly Lace, 92.2) over a dark existing wall — the case a naive
    /// alpha blend cannot produce, since blending toward white over near-black yields grey.
    static let all: [PaintColor] = published + warmEstimates

    /// Entries whose LRV is a published figure.
    ///
    /// Verifiable against the swatch: for the light neutrals here the sRGB luminance lands within
    /// ~2% of the stated LRV, while Van Deusen Blue and Hale Navy sit ~28% *below* theirs. That gap
    /// is why the renormalisation exists, and it is the reason a swatch-derived LRV is not an
    /// acceptable substitute for a measured one.
    static let published: [PaintColor] = [
        PaintColor(id: "OC-65",    name: "Chantilly Lace",  code: "OC-65",    hex: 0xF4F4EF, lrv: 92.20),
        PaintColor(id: "OC-117",   name: "Simply White",    code: "OC-117",   hex: 0xF3F0E4, lrv: 89.52),
        PaintColor(id: "OC-17",    name: "White Dove",      code: "OC-17",    hex: 0xF0EDE1, lrv: 85.38),
        PaintColor(id: "OC-20",    name: "Pale Oak",        code: "OC-20",    hex: 0xE0D9CF, lrv: 68.99),
        PaintColor(id: "OC-52",    name: "Gray Owl",        code: "OC-52",    hex: 0xD3D5CE, lrv: 65.77),
        PaintColor(id: "HC-172",   name: "Revere Pewter",   code: "HC-172",   hex: 0xCCC6B8, lrv: 55.51),
        PaintColor(id: "2124-46",  name: "Wrought Iron",    code: "2124-46",  hex: 0x474B4C, lrv:  6.16),
        PaintColor(id: "HC-166",   name: "Kendall Charcoal",code: "HC-166",   hex: 0x67655C, lrv: 13.34),
        PaintColor(id: "HC-156",   name: "Van Deusen Blue", code: "HC-156",   hex: 0x4A5B6B, lrv: 12.94),
        PaintColor(id: "HC-154",   name: "Hale Navy",       code: "HC-154",   hex: 0x434C52, lrv:  8.85)
    ]

    /// Warm colours added to give the demo something other than neutrals to show.
    ///
    /// **Their LRVs are estimates and must be replaced before any accuracy claim.** The hexes are
    /// plausible representations and the LRVs are approximate published figures, neither verified
    /// against a drawdown. That is the same caveat `CLAUDE.md` already records for the catalogue as
    /// a whole, but it is worth restating here because these are the entries where it bites: the
    /// error is small for the near-whites and largest for the saturated dark ones, exactly where
    /// the measured data in `published` diverges most from its swatch.
    ///
    /// Chosen to span LRV rather than to look attractive together. A warm mid-LRV colour exercises
    /// the spatially varying tint term — dividing local chromaticity by the wall's mean — far
    /// harder than a neutral does, because an error in that term reads as a colour cast rather
    /// than as a lightness shift, and mixed-illuminant rooms are where a paint visualiser gets
    /// challenged.
    ///
    /// Deliberately not imported from the ARPaint catalogue: its 38 colours peak at 38% saturation
    /// and its warm entries are 5–12% beiges, three of which (Pale Oak, White Dove, Revere Pewter)
    /// are already above. There was no warmth there to borrow.
    static let warmEstimates: [PaintColor] = [
        PaintColor(id: "OC-12",    name: "Muslin",          code: "OC-12",    hex: 0xE9DFCC, lrv: 72.0),
        PaintColor(id: "HC-81",    name: "Manchester Tan",  code: "HC-81",    hex: 0xD8CDB4, lrv: 64.0),
        PaintColor(id: "HC-80",    name: "Bleeker Beige",   code: "HC-80",    hex: 0xC6B49A, lrv: 44.0),
        PaintColor(id: "2175-40",  name: "Terra Cotta",     code: "2175-40",  hex: 0xC97F5E, lrv: 30.0),
        PaintColor(id: "HC-50",    name: "Georgian Brick",  code: "HC-50",    hex: 0x9A5B45, lrv: 18.0),
        PaintColor(id: "HC-70",    name: "Van Buren Brown", code: "HC-70",    hex: 0x6E4B3B, lrv: 11.0)
    ]

    static let `default` = all[0]
}
