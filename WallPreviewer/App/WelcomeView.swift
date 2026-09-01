import SwiftUI

/// The screen the app opens on, every launch.
///
/// It earns its place by doing two things before the camera starts. It sets the expectation that
/// this is a *measurement* — the colour you see is the paint under your own light, not a tint laid
/// over a photo — and it says the one thing people need to know to get a wall detected at all,
/// which is that a blank expanse of drywall gives ARKit nothing to track and a corner or an outlet
/// in frame fixes it. Both are much cheaper to say here than to discover in front of a wall.
///
/// It is also where camera permission gets requested, since `ARSession.run` is deferred until
/// `onStart` fires. The system prompt then lands on a screen that has already explained why.
struct WelcomeView: View {

    /// Called when Get Started is tapped. The AR session starts only after this.
    let onStart: () -> Void

    /// Colours in the hero fan, front to back. Chosen to span the catalogue's LRV range rather
    /// than to coordinate — the spread is the point, since it is what the renderer is for.
    private static let fan = ["HC-154", "HC-50", "HC-80", "OC-20", "OC-65"]
        .compactMap { id in PaintCatalog.all.first { $0.id == id } }

    var body: some View {
        ZStack {
            AppBackground()

            VStack(spacing: 0) {
                Spacer(minLength: 24)

                hero
                    .padding(.bottom, 40)

                VStack(spacing: 10) {
                    Text("Wall Previewer")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text("See a paint colour on your own wall,\nunder your own light.")
                        .font(.system(size: 16))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 32)

                VStack(alignment: .leading, spacing: 20) {
                    step(icon: "viewfinder",
                         title: "Point at a wall",
                         detail: "Pan slowly until it's found, then tap to select it.")
                    step(icon: "paintpalette.fill",
                         title: "Pick a colour",
                         detail: "Sixteen colours, each with its published light reflectance.")
                    step(icon: "sun.max.fill",
                         title: "Keep the shadows",
                         detail: "Your wall's shading and texture carry through, so a light colour still reads light over a dark wall.")
                }
                .frame(maxWidth: 380)
                .padding(.horizontal, 8)

                Spacer(minLength: 32)

                VStack(spacing: 14) {
                    Button(action: onStart) {
                        Text("Get Started")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(.white, in: Capsule())
                            .foregroundStyle(.black)
                    }
                    .buttonStyle(.plain)

                    Text("Uses the camera. Works best with a corner, some trim, or an outlet in frame.")
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.4))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 380)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
        .statusBarHidden()
    }

    // MARK: - Pieces

    /// Overlapping chips, fanned like a deck pulled part way open.
    ///
    /// Drawn back to front with a rotation and a rising offset, so the row reads as physical stock
    /// rather than as a colour legend.
    private var hero: some View {
        ZStack {
            ForEach(Array(Self.fan.enumerated().reversed()), id: \.element.id) { index, colour in
                let position = Double(index)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(paint: colour))
                    .frame(width: 96, height: 128)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.45), radius: 14, x: 0, y: 8)
                    .rotationEffect(.degrees(position * 7 - 14))
                    .offset(x: position * 30 - 60, y: abs(position - 2) * 7)
            }
        }
        .frame(height: 150)
        .accessibilityHidden(true)
    }

    private func step(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 15) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 38, height: 38)
                .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

/// The ground both pre-camera screens sit on.
///
/// Deep neutral rather than pure black, with a warm bloom at the top. The bloom is doing real work
/// on the welcome screen: it warms the chips it sits behind, which is a quiet preview of the thing
/// the app does — a swatch is not a fixed appearance, it is a reflectance under some light. Pure
/// black would render them as flat product shots.
struct AppBackground: View {
    var body: some View {
        LinearGradient(
            colors: [Color(red: 0.13, green: 0.12, blue: 0.13),
                     Color(red: 0.05, green: 0.05, blue: 0.06)],
            startPoint: .top,
            endPoint: .bottom
        )
        .overlay(alignment: .top) {
            RadialGradient(
                colors: [Color(red: 0.98, green: 0.85, blue: 0.66).opacity(0.16), .clear],
                center: .top,
                startRadius: 0,
                endRadius: 420
            )
        }
        .ignoresSafeArea()
    }
}

extension Color {
    /// The paint's published swatch, for UI chrome only.
    ///
    /// This is *not* how the colour reaches the wall. The renderer takes the chromaticity from
    /// this hex, rescales its luminance to the measured LRV, and adapts it to the scene
    /// illuminant — see ``PaintColor/linearReflectance``. A swatch shown here and the same paint
    /// shown on a wall are therefore expected to differ, and the wall is the accurate one.
    init(paint: PaintColor) {
        self.init(red: Double((paint.hex >> 16) & 0xFF) / 255,
                  green: Double((paint.hex >> 8) & 0xFF) / 255,
                  blue: Double(paint.hex & 0xFF) / 255)
    }
}

#Preview {
    WelcomeView {}
}
