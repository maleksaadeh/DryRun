import simd

/// A paint colour, stored as spectral-surrogate reflectance data.
///
/// A colour is two numbers, not one. There is the sRGB swatch, which is chosen to look right on a
/// screen, and there is the **LRV** (Light Reflectance Value), which for a real paint is measured
/// off a physical drawdown with an instrument. For manufacturer colours these disagree more often
/// than not, and where they conflict this type trusts the LRV — what the result gets judged
/// against is paint on a wall, not a swatch on a website.
struct PaintColor: Identifiable, Hashable, Codable, Sendable {
    let id: String
    /// Display name, e.g. "Terracotta".
    let name: String
    /// Manufacturer code where there is one, empty otherwise. Callers must handle the empty case:
    /// the built-in colours have no code, and the custom-colour form makes it optional.
    let code: String
    /// Published sRGB swatch, used for hue and saturation only.
    let hex: UInt32
    /// Published Light Reflectance Value, 0–100. Treated as authoritative for lightness.
    let lrv: Float
    /// Whether the user entered this colour rather than it shipping in ``PaintCatalog``.
    ///
    /// Drives the paid gate: a custom colour is stored, listed and editable for everyone, but
    /// reaches the renderer only when ``Entitlements/isUnlocked``. Catalogue colours are never
    /// gated. Defaulted so every existing `PaintCatalog` entry constructs unchanged.
    var isCustom = false

    /// Linear-light reflectance in the sRGB primaries, with luminance rescaled to match ``lrv``.
    ///
    /// Takes the chromaticity implied by ``hex`` but renormalises so the colour's luminance
    /// equals ``lrv``. This is what makes a light-over-dark render land correctly: getting an
    /// off-white's *lightness* wrong by 8 LRV points is instantly obvious next to the real thing,
    /// whereas a small hue error is not.
    ///
    /// For the built-in colours the two already agree, so this scales by 1 — see ``PaintCatalog``.
    /// It does real work for a manufacturer colour, and for anything a user enters by hand.
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
    ///   match under a spiky spectrum — metamerism. Spectral data for the paint itself is the
    ///   only real fix; this is a known limit rather than an oversight.
    func adaptedReflectance(under illuminant: SIMD3<Float>) -> SIMD3<Float> {
        let xyz = ColorScience.srgbToXYZ * linearReflectance
        return xyz * (illuminant / ColorScience.d65)
    }
}

/// The colours the app ships with.
///
/// ## Why these are generic rather than a manufacturer's palette
///
/// Two reasons, and the second is the interesting one.
///
/// A real palette is a trademark. Shipping a manufacturer's colour names and codes in an app
/// someone pays for makes a claim about their product, using their marks, without their agreement
/// — a licensing question rather than an engineering one, and not worth carrying by accident.
///
/// More usefully: an invented colour has no external truth to be wrong about. For a real paint the
/// LRV is a measurement, taken off a drawdown with an instrument, and the published swatch usually
/// disagrees with it — which is the entire reason ``PaintColor/linearReflectance`` renormalises one
/// against the other. For the colours below the LRV *is* the swatch's own luminance, computed from
/// the hex rather than asserted about a can of paint that exists somewhere. The renormalisation
/// becomes a no-op, and the pair is exact by construction instead of being an approximation
/// nobody can check.
///
/// That property does not survive contact with a real palette. If a licensed one is added later,
/// every LRV in it must come from the manufacturer, and the guidance below applies again in full.
///
/// ## The three
///
/// Chosen to span the LRV range rather than to coordinate with each other, because the spread is
/// what exercises the renderer:
///
/// | Colour | LRV | What it exercises |
/// |---|---|---|
/// | Soft White | 86.4 | A light colour over a dark wall — the case an alpha blend cannot do |
/// | Powder Blue | 53.2 | A mid-LRV colour, where shading detail is most visible |
/// | Terracotta | 20.4 | A warm dark, which drives the spatially varying tint term hardest |
///
/// ## Adding a colour
///
/// One entry appended to ``all``:
///
/// ```swift
/// PaintColor(id: "sage", name: "Sage", code: "", hex: 0x9FAE93, lrv: 41.2),
/// ```
///
/// - `id` — any unique string; a lowercase slug is the convention here.
/// - `name`, `code` — shown in the UI and stored with any capture taken. `code` may be empty.
/// - `hex` — the sRGB swatch, as an integer literal (`0xRRGGBB`).
/// - `lrv` — Light Reflectance Value, 0–100.
///
/// Files sit in a synchronized group, so nothing needs registering in the project. Note that the
/// swatch row draws from ``featured`` — today that is simply ``all``, but if the two ever diverge,
/// a colour added here stays invisible until it is listed there too.
///
/// For a new *invented* colour, set `lrv` to the hex's own luminance so it stays exact by
/// construction. That is `dot(ColorScience.srgbToLinear(rgb), (0.2126729, 0.7151522, 0.0721750))`
/// times 100 — the same expression ``PaintColor/linearReflectance`` uses.
///
/// ### Why LRV is not optional
///
/// `linearReflectance` keeps only the *chromaticity* of `hex` and renormalises its luminance to
/// match `lrv`. The swatch decides the hue, LRV decides the lightness. Supplying a wrong LRV gives
/// the right colour at the wrong lightness — the one error this renderer exists to avoid, since
/// the result gets held up against a real painted surface.
///
/// ### For a real manufacturer colour
///
/// The figure is on the manufacturer's page for that colour and printed on fan-deck chips. Do not
/// substitute the swatch's own luminance, which is where the two diverge:
///
/// | Colour | Swatch luminance vs published LRV |
/// |---|---|
/// | Light / low-saturation (LRV > 50) | within ~2–5% — close enough to derive |
/// | Dark / saturated (LRV < 25) | swatch runs **25–30% too dark** |
///
/// A deep navy is the worst case: its published swatch typically reads a quarter darker than the
/// paint measures, so deriving the LRV from it renders the wall visibly too dark. This is also why
/// `CustomColorForm` makes the user type an LRV rather than offering to guess one.
enum PaintCatalog {

    /// The full catalogue.
    ///
    /// The LRVs are each colour's own swatch luminance to two decimal places, so
    /// ``PaintColor/linearReflectance`` scales by a factor of 1 and the rendered colour is exactly
    /// what the hex describes, adapted to the room's light.
    static let all: [PaintColor] = [
        PaintColor(id: "soft-white",  name: "Soft White",  code: "", hex: 0xF2EFE7, lrv: 86.38),
        PaintColor(id: "powder-blue", name: "Powder Blue", code: "", hex: 0xA9C5D6, lrv: 53.22),
        PaintColor(id: "terracotta",  name: "Terracotta",  code: "", hex: 0xB26B45, lrv: 20.41)
    ]

    /// The colours offered in the swatch row, in order.
    ///
    /// Identical to ``all`` while the catalogue is three colours. It stays a separate property
    /// because it is the seam that matters if a licensed palette is ever added: `all` would grow to
    /// hundreds, and this would become the handful shown without scrolling, with the rest reachable
    /// through a search field.
    static let featured: [PaintColor] = all

    /// The colour selected at launch.
    static let `default` = all[0]
}
