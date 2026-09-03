import SwiftUI

/// The screen the app opens on, every launch.
struct WelcomeView: View {

    /// Whether to warn that this iPhone has no LiDAR scanner.
    var warnsAboutLiDAR = false

    /// Called when Get Started is tapped. The AR session starts only after this.
    let onStart: () -> Void

    @State private var showingLiDARWarning = false
    @State private var showingHowItWorks = false

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

                    Text("See a paint color on your own wall,\nunder your own light.")
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
                         title: "Pick a color",
                         detail: "Each one carries its published light reflectance, so it lands at the right lightness.")
                    step(icon: "sun.max.fill",
                         title: "Keep the shadows",
                         detail: "Your wall's shading and texture carry through, so a light color still reads light over a dark wall.")
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

                    Text("Uses the camera.")
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
        .overlay(alignment: .topTrailing) {
            Button { showingHowItWorks = true } label: {
                Image(systemName: "questionmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.10), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("How it works")
            .padding(.top, 10)
            .padding(.trailing, 18)
        }
        .statusBarHidden()
        .sheet(isPresented: $showingHowItWorks) {
            HowItWorksView()
        }
        .onAppear { showingLiDARWarning = warnsAboutLiDAR }
        .alert("This iPhone has no LiDAR", isPresented: $showingLiDARWarning) {
            Button("Continue Anyway") {}
        } message: {
            Text("""
                 DryRun uses the LiDAR scanner to tell your wall apart from whatever is in front \
                 of it. Without it the colour still works, but paint will spread over furniture, \
                 doorways and anything else in frame.

                 LiDAR is only on iPhone Pro models, from iPhone 12 Pro onward.
                 """)
        }
    }

    // MARK: - Pieces

    /// Overlapping chips, fanned like a part-opened deck.
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

/// The ground both pre-camera screens sit on: deep neutral with a warm bloom at the top.
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

#Preview("Welcome") {
    WelcomeView {}
}

#Preview("No LiDAR") {
    WelcomeView(warnsAboutLiDAR: true) {}
}
