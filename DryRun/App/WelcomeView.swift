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

    /// Colours in the hero fan, front to back.
    ///
    /// The offered palette itself rather than a decorative selection, so the welcome screen cannot
    /// advertise a colour the picker does not have. ``PaintCatalog/featured`` already spans the
    /// LRV range deliberately, which is the spread this wants anyway.
    private static let fan = PaintCatalog.featured

    var body: some View {
        ZStack {
            AppBackground()

            VStack(spacing: 0) {
                Spacer(minLength: 24)

                hero
                    .padding(.bottom, 40)

                VStack(spacing: 10) {
                    Text("DryRun")
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
                         detail: "Each one carries its published light reflectance, so it lands at the right lightness.")
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
    ///
    /// Laid out from each chip's distance to the centre of the row rather than from its index, so
    /// the fan stays symmetric whatever ``PaintCatalog/featured`` holds. `spread` is the only knob
    /// worth touching: below about 30 the middle chips disappear behind their neighbours.
    private var hero: some View {
        let centre = Double(Self.fan.count - 1) / 2
        let spread: Double = 36

        return ZStack {
            ForEach(Array(Self.fan.enumerated().reversed()), id: \.element.id) { index, colour in
                let fromCentre = Double(index) - centre
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(paint: colour))
                    .frame(width: 96, height: 128)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.45), radius: 14, x: 0, y: 8)
                    .rotationEffect(.degrees(fromCentre * 7))
                    .offset(x: fromCentre * spread, y: abs(fromCentre) * 7)
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

#Preview {
    WelcomeView {}
}
