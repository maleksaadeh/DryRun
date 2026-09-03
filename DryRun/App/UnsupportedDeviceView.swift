import SwiftUI

/// Shown in place of everything else when the device cannot run the app.
struct UnsupportedDeviceView: View {

    let verdict: DeviceCapability.Verdict

    var body: some View {
        ZStack {
            AppBackground()

            VStack(spacing: 18) {
                Image(systemName: icon)
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.bottom, 6)

                Text(title)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if let footnote {
                    Text(footnote)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: 340)
            .padding(.horizontal, 32)
        }
        .statusBarHidden()
    }

    // MARK: - Copy

    private var icon: String {
        switch verdict {
        case .noLiDAR:         "cube.transparent"
        case .noWorldTracking: "iphone"
        case .noMetal:         "exclamationmark.triangle"
        case .supported:       "checkmark.circle"
        }
    }

    private var title: String {
        switch verdict {
        case .noLiDAR:         "Requires iPhone Pro"
        case .noWorldTracking: "Requires a physical iPhone"
        case .noMetal:         "Unsupported device"
        case .supported:       "Ready"
        }
    }

    private var message: String {
        switch verdict {
        case .noLiDAR:
            "DryRun uses the LiDAR scanner to measure where your wall ends and what is standing in front of it. Without it, paint would cover your furniture along with the wall."
        case .noWorldTracking:
            "DryRun needs ARKit world tracking, which the Simulator cannot provide."
        case .noMetal:
            "No Metal renderer is available on this device, so the wall cannot be drawn."
        case .supported:
            ""
        }
    }

    private var footnote: String? {
        switch verdict {
        case .noLiDAR:         "LiDAR is on iPhone 12 Pro and later Pro models."
        case .noWorldTracking: "Run it on a physical iPhone Pro."
        case .noMetal, .supported: nil
        }
    }
}

#Preview("No LiDAR") {
    UnsupportedDeviceView(verdict: .noLiDAR)
}

#Preview("Simulator") {
    UnsupportedDeviceView(verdict: .noWorldTracking)
}
