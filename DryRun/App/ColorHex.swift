import SwiftUI

extension Color {

    /// A 24-bit `0xRRGGBB` value as an sRGB colour.
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }

    /// The paint's published swatch, for UI chrome only.
    ///
    /// This is *not* how the colour reaches the wall. The renderer takes the chromaticity from
    /// this hex, rescales its luminance to the measured LRV, and adapts it to the scene
    /// illuminant — see ``PaintColor/linearReflectance``. A swatch shown in the UI and the same
    /// paint shown on a wall are therefore expected to differ, and the wall is the accurate one.
    init(paint: PaintColor) {
        self.init(hex: paint.hex)
    }

    /// The nearest `0xRRGGBB` value, for reading a `ColorPicker` selection back out.
    ///
    /// `UIColor(self)` can hand back components outside 0–1: the system picker works in Display
    /// P3, whose gamut is wider than sRGB, and out-of-gamut channels come through as extended
    /// values. Clamping folds them to the nearest sRGB colour, which is the right answer here
    /// because the entire render pipeline is sRGB — see the note on ``ColorScience/xyzToSRGB``.
    /// Architectural paint is low-chroma and sits well inside sRGB, so the clamp is reachable
    /// mainly by someone dragging the picker into a saturation no wall paint has.
    var hexValue: UInt32 {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let channel = { (value: CGFloat) in UInt32(max(0, min(1, value)) * 255 + 0.5) }
        return channel(red) << 16 | channel(green) << 8 | channel(blue)
    }
}

extension UInt32 {

    /// Parses `RRGGBB` or `#RRGGBB`, case-insensitively.
    ///
    /// Six digits only. Accepting the three-digit shorthand would mean `#ABC` and `#AABBCC` are
    /// the same colour typed two ways, and a paint code pasted from a manufacturer's page is
    /// always the long form anyway.
    init?(hexString: String) {
        var digits = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self = value
    }

    /// Formatted as `#RRGGBB`, the form the field displays and the manufacturer publishes.
    var hexString: String { String(format: "#%06X", self) }
}
