import SwiftUI

@main
struct WallPreviewerApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                // The camera screen is a dark surface with material controls over live video, and
                // the welcome screen is built to match it. Neither has a light appearance to fall
                // back to, so the scheme is stated rather than inherited.
                .preferredColorScheme(.dark)
        }
    }
}

/// Checks the hardware, then holds the app at the welcome screen until Get Started is tapped.
///
/// The Get Started gate is state on this view, not a persisted flag, so it comes back on every
/// cold launch. That is the intended behaviour rather than an oversight: `ARSession.run` is what
/// triggers the camera permission prompt and starts world tracking, and deferring both behind an
/// explicit tap means the app never opens straight into a live camera.
struct RootView: View {

    @State private var hasStarted = false

    /// Evaluated once, before anything is drawn.
    ///
    /// A `let` rather than `@State` because the answer is a property of the hardware and cannot
    /// change while the app is running — re-checking it on every body evaluation would be pure
    /// cost. This is the app's only real enforcement of its LiDAR requirement; see
    /// ``DeviceCapability`` for why `Info.plist` cannot carry it.
    private let verdict = DeviceCapability.evaluate()

    var body: some View {
        Group {
            switch verdict {
            case .supported:
                if hasStarted {
                    camera
                } else {
                    WelcomeView {
                        withAnimation(.easeInOut(duration: 0.35)) { hasStarted = true }
                    }
                    .transition(.opacity)
                }
            case .noWorldTracking, .noLiDAR, .noMetal:
                UnsupportedDeviceView(verdict: verdict)
            }
        }
    }

    @ViewBuilder
    private var camera: some View {
        // Unreachable in practice — `verdict` already established there is a Metal device — but
        // `ContentView.init` is failable for pipeline construction too, and a black screen is the
        // worst possible way to report that.
        if let content = ContentView() {
            content.transition(.opacity)
        } else {
            UnsupportedDeviceView(verdict: .noMetal)
        }
    }
}
