import SwiftUI

@main
struct DryRunApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
        }
    }
}

/// Checks the hardware, then holds at the welcome screen until Get Started is tapped.
struct RootView: View {

    @State private var hasStarted = false

    private let verdict = DeviceCapability.evaluate()

    var body: some View {
        Group {
            if verdict.isFatal {
                UnsupportedDeviceView(verdict: verdict)
            } else if hasStarted {
                camera
            } else {
                WelcomeView(warnsAboutLiDAR: verdict == .noLiDAR) {
                    withAnimation(.easeInOut(duration: 0.35)) { hasStarted = true }
                }
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var camera: some View {
        if let content = ContentView() {
            content.transition(.opacity)
        } else {
            UnsupportedDeviceView(verdict: .noMetal)
        }
    }
}
