import SwiftUI

/// The explainer behind the "?" on the welcome screen.
///
/// Written for someone standing in a room holding a phone, not for someone who knows what LRV or
/// time-of-flight means. Each section says what the app does and, briefly, why that is not the
/// obvious thing — because the obvious thing (tint the picture) is what makes other paint
/// visualizers wrong, and saying so is what earns trust in the result.
///
/// The accuracy note is deliberately not buried at the bottom in grey 9pt. Anyone about to spend
/// money on paint deserves to be told plainly that a screen is not a paint chip.
struct HowItWorksView: View {

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        section(
                            icon: "number",
                            title: "Every color is two numbers",
                            body: """
                                  Paint colors come with a code from the manufacturer and an \
                                  LRV — a Light Reflectance Value from 0 to 100, measured off a \
                                  real painted sample.

                                  The swatch decides the hue. The LRV decides how light it is. \
                                  DryRun trusts the LRV, which is why a pale color still reads \
                                  pale over a dark wall instead of coming out gray.
                                  """)

                        section(
                            icon: "wave.3.right",
                            title: "Infrared finds the wall",
                            body: """
                                  The scanner on the back of your iPhone sends out invisible \
                                  infrared light and times how long it takes to bounce back. That \
                                  is how DryRun knows where your wall is, and what is standing in \
                                  front of it — a couch, a door frame, you.

                                  At the same time the camera reads the light already in the \
                                  room: the shadows, the warm lamp in the corner, the daylight \
                                  from the window.
                                  """)

                        section(
                            icon: "sun.max.fill",
                            title: "Your light stays put",
                            body: """
                                  DryRun does not tint the picture. It replaces the wall's color \
                                  outright, then lays your room's own shading back over the top.

                                  Shadows, texture, and the way light falls across the wall all \
                                  survive — which is what makes it look like paint rather than a \
                                  colored rectangle.
                                  """)

                        section(
                            icon: "eyedropper.halffull",
                            title: "Bring your own color",
                            body: """
                                  Found a color that isn't here? Tap + in the swatch row and \
                                  enter its hex value and published LRV — both are on the \
                                  manufacturer's page for that color, and the LRV is printed on \
                                  fan-deck chips.

                                  Adding and editing your colors is free. Seeing one of them on \
                                  your wall is a paid unlock.
                                  """)

                        disclaimer
                    }
                    .frame(maxWidth: 460, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("How It Works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Pieces

    private func section(icon: String, title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.09),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text(body)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)
        }
    }

    /// Boxed rather than run in with the rest, so it reads as a caveat and not as another feature.
    private var disclaimer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 14))
                Text("It won't be exact")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(.orange.opacity(0.95))

            Text("""
                 What you see here is close, but a screen is not a paint chip. Your display, the \
                 camera, and the light in the room each shift the color a little, and DryRun \
                 estimates the room's light rather than measuring it with an instrument.

                 Treat it as a strong preview, not a match.
                 """)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)
        }
        .padding(16)
        .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.orange.opacity(0.28), lineWidth: 1)
        }
    }
}

#Preview {
    HowItWorksView()
}
