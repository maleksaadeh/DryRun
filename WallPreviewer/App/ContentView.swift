import SwiftUI
import Metal

/// The camera screen: point at a wall, tap it, pick a colour.
///
/// There is one render path — the wall repainted with its own shading and texture intact — so
/// there is no mode control here. Everything the wall's appearance depends on is either measured
/// (the illuminant, the shading field) or a property of the paint (its LRV), and none of it is a
/// choice worth putting in front of someone deciding on a colour.
struct ContentView: View {
    @StateObject private var controller: ARSessionController
    @StateObject private var calibration = CaptureCalibration()
    private let renderer: WallRenderer

    @State private var paint = PaintCatalog.default
    @State private var detailGain: Float = 0.6
    @State private var occluderBounds = OccluderBounds.default
    /// Whether the tuning stack is on screen. Collapsed by someone who wants to look at the wall
    /// rather than at the controls — which, when judging a colour, is most of the time.
    @State private var showsControls = true
    /// Digital zoom, and the value it had when the current pinch began.
    @State private var zoom: Float = 1
    @State private var zoomAtGestureStart: Float = 1
    @State private var store = CaptureStore()
    @State private var showsGallery = false
    /// Bumped once per shutter press; the renderer captures one frame per distinct value.
    @State private var captureToken = 0
    /// True from the press until the still has been written, to keep the shutter from re-firing.
    @State private var isCapturing = false
    @State private var captureNote: String?

    /// Main actor because it builds the renderer, which is main-actor isolated. SwiftUI already
    /// constructs views on the main thread, so this states the existing reality rather than
    /// constraining anything new.
    @MainActor
    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = WallRenderer(device: device) else { return nil }
        self.renderer = renderer
        _controller = StateObject(wrappedValue: ARSessionController(device: device))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ARWallView(controller: controller,
                       calibration: calibration,
                       renderer: renderer,
                       paint: paint,
                       detailGain: detailGain,
                       occluderBounds: occluderBounds,
                       zoom: zoom,
                       captureToken: captureToken,
                       onCapture: handleCapture)
                .ignoresSafeArea()
                // The Metal view takes no touches at all. Anything hit-testable spanning the full
                // screen competes with the controls stacked above it, and wins often enough to
                // make them feel dead.
                .allowsHitTesting(false)

            // Wall selection lives on its own transparent layer, below the controls in the ZStack,
            // so SwiftUI resolves it by z-order: a tap on the picker reaches the picker, and only
            // a tap on open camera reaches here.
            GeometryReader { geometry in
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { location in
                        // The app is portrait-locked in Info.plist, so the raycast's orientation
                        // is fixed; there is no window scene to consult from here.
                        controller.selectWall(at: location,
                                              viewportSize: geometry.size,
                                              orientation: .portrait)
                    }
                    // Sharing this surface with the tap is deliberate: SwiftUI separates them by
                    // touch count, so a one-finger tap still selects a wall while two fingers
                    // zoom. A separate overlay would have to sit above or below the tap layer,
                    // and either way one of the two would stop responding.
                    .gesture(
                        MagnifyGesture()
                            .onChanged { value in
                                let proposed = zoomAtGestureStart * Float(value.magnification)
                                zoom = min(max(proposed, minimumZoom(viewport: geometry.size)),
                                           Self.maximumZoom)
                            }
                            .onEnded { _ in zoomAtGestureStart = zoom }
                    )
            }
            .ignoresSafeArea()

            VStack(spacing: 12) {
                Spacer()
                if showsControls {
                    surfaceControl
                    swatches
                }
                shutterRow
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)

            // Kept in its own layer above the controls so it stays reachable when they are
            // hidden, and so it never lands under the tap surface that selects walls.
            sessionControls

            if let prompt {
                Text(prompt)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.horizontal, 60)
                    .padding(.top, 14)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.opacity)
            }

            if let captureNote {
                Text(captureNote)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.opacity)
            }
        }
        .fullScreenCover(isPresented: $showsGallery) {
            GalleryView(store: store)
        }
        .onChange(of: showsGallery) { _, isShowing in
            // Nothing to render behind an opaque screen, and a paint session runs long enough for
            // thermal headroom to be worth protecting.
            if isShowing { controller.pause() } else { controller.resume() }
        }
        .animation(.easeInOut(duration: 0.22), value: showsControls)
        .animation(.easeInOut(duration: 0.22), value: prompt)
        .statusBarHidden()
        .onAppear {
            calibration.begin()
            controller.start()
        }
        .onDisappear { controller.pause() }
    }

    /// The one line of guidance on screen, or nothing once there is paint to look at.
    ///
    /// Deliberately not a permanent status readout. Before a wall is selected there is genuinely
    /// something to say — most people do not know a blank wall needs a corner or an outlet in
    /// frame before ARKit will find it — and afterwards there is not, so it leaves.
    ///
    /// The tracking note outranks it because that one names a condition the *room* has to fix.
    private var prompt: String? {
        if let note = controller.trackingNote { return note }
        if controller.selectedWallID == nil { return controller.status }
        return nil
    }

    /// Upper zoom limit.
    ///
    /// Capped at 3x because this is a crop, not a lens: past roughly that the drawable is
    /// magnifying so few camera pixels that the wall's own texture — the detail the relight path
    /// works hard to preserve — turns to mush, which undercuts the thing the zoom is for.
    static let maximumZoom: Float = 3

    /// Lower zoom limit: the point where the entire captured frame is on screen.
    ///
    /// Zooming out is not padding. `ARFrame.displayTransform` aspect-*fills*, so a tall portrait
    /// viewport is already cropping a 4:3 capture horizontally — at 1x a meaningful slice of the
    /// frame is off screen, and only zooming below 1 reveals it. That is genuinely useful here,
    /// since fitting a whole wall on screen is most of what a paint preview is for.
    ///
    /// Aspect-fill shows `min(a, b) / max(a, b)` of the source, so that ratio is exactly the zoom
    /// at which nothing is cropped. Stopping there is deliberate: further out only adds letterbox
    /// bars, shrinking the wall for no extra view.
    private func minimumZoom(viewport: CGSize) -> Float {
        guard let cameraAspect = controller.cameraAspect,
              cameraAspect > 0, viewport.width > 0, viewport.height > 0 else { return 1 }
        let viewportAspect = Float(viewport.width / viewport.height)
        let fit = min(viewportAspect, cameraAspect) / max(viewportAspect, cameraAspect)
        // Guard against a format that needs no crop at all, which would otherwise allow 1x only.
        return min(fit, 1)
    }

    /// Reset and show/hide, pinned top-trailing.
    ///
    /// Reset matters more than it looks. `selectWall` deliberately falls back to the largest known
    /// wall when a raycast misses, so tapping can never *deselect* — without this there is no way
    /// back to an unpainted view once anything has been selected.
    private var sessionControls: some View {
        VStack(spacing: 10) {
            Button {
                showsControls.toggle()
            } label: {
                Image(systemName: showsControls ? "chevron.down" : "chevron.up")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showsControls ? "Hide controls" : "Show controls")

            if abs(zoom - 1) > 0.01 {
                Button {
                    zoom = 1
                    zoomAtGestureStart = 1
                } label: {
                    Text(String(format: "%.1f×", zoom))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reset zoom to 1x")
            }

            if controller.selectedWallID != nil {
                Button {
                    controller.clearSelection()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear painted wall")
            }
        }
        .padding(.top, 12)
        .padding(.trailing, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    /// Shutter, with the gallery beside it.
    ///
    /// Outside the collapsible stack: hiding the tuning controls is how you get a clean look at
    /// the wall, which is exactly the moment you are most likely to want a photo of it.
    private var shutterRow: some View {
        HStack {
            Button {
                showsGallery = true
            } label: {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(.ultraThinMaterial)
                        .frame(width: 44, height: 44)
                        .overlay {
                            if let newest = store.captures.first,
                               let thumbnail = store.thumbnail(for: newest) {
                                Image(uiImage: thumbnail)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 44, height: 44)
                                    .clipShape(RoundedRectangle(cornerRadius: 9))
                            } else {
                                Image(systemName: "photo.on.rectangle.angled")
                                    .font(.system(size: 17))
                            }
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 9)
                                .stroke(.white.opacity(0.35), lineWidth: 1)
                        }
                    if !store.captures.isEmpty {
                        Text("\(store.captures.count)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.white, in: Capsule())
                            .offset(x: 7, y: -6)
                    }
                }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: capture) {
                ZStack {
                    Circle().fill(.white).frame(width: 58, height: 58)
                    Circle().strokeBorder(.white.opacity(0.9), lineWidth: 3).frame(width: 68, height: 68)
                }
            }
            .buttonStyle(.plain)
            .disabled(isCapturing)

            // Balances the row so the shutter sits centred.
            Color.clear.frame(width: 44, height: 44)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.top, 4)
    }

    /// Asks the renderer for the next composited frame and files it with the paint that produced it.
    private func capture() {
        guard !isCapturing else { return }
        isCapturing = true
        captureToken += 1
    }

    /// Files the frame the renderer handed back.
    ///
    /// Explicitly main actor: it mutates view state, and the isolation is also what allows it to be
    /// passed to the renderer as a `Sendable` completion handler.
    @MainActor
    private func handleCapture(_ image: CGImage?) {
        guard isCapturing else { return }
        isCapturing = false

        guard let image else {
            show("Couldn't read the frame.")
            return
        }
        let record = Capture(id: UUID(),
                             createdAt: Date(),
                             paintName: paint.name,
                             paintCode: paint.code,
                             paintLRV: paint.lrv,
                             zoom: zoom)
        show(store.save(image, describing: record) ? "Saved" : "Couldn't save the capture.")
    }

    private func show(_ message: String) {
        captureNote = message
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            captureNote = nil
        }
    }

    /// Tunes how far off the wall something must stand before paint stops covering it.
    ///
    /// Exposed rather than hardcoded because the correct value is a property of the room, not of
    /// the code: a television on a slim mount sits ~3 cm off the plaster, one on an articulating
    /// arm far more, and the LiDAR noise floor that sets the lower limit varies with range.
    private var surfaceControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Surface depth")
                    .font(.caption.weight(.medium))
                Spacer()
                Text(surfaceDepthLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Slider(value: $occluderBounds.band,
                   in: OccluderBounds.range) {
                Text("Surface depth")
            }
            .tint(.white)

            // A/B switch rather than a setting. Mesh classification is coarse, and a false positive
            // subtracts paint from real wall — so the way to judge it is to watch the difference on
            // an actual doorway, not to trust it by default and hope.
            Toggle(isOn: $controller.excludesOpenings) {
                Text("Exclude doors & windows")
                    .font(.caption.weight(.medium))
            }
            .toggleStyle(.switch)
            .tint(.white)
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    /// Plain-language stand-in for the slider's raw metres.
    ///
    /// What the number means is "how far off the wall a thing has to be before it stops being
    /// painted", which is not a quantity anyone holding a phone is in a position to estimate. The
    /// three bands are what the choice actually amounts to: keep the trim and switch plates
    /// painted, or keep the television out of it.
    private var surfaceDepthLabel: String {
        switch occluderBounds.band {
        case ..<0.015: "Tight"
        case ..<0.035: "Balanced"
        default:       "Loose"
        }
    }

    private var swatches: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(PaintCatalog.all) { colour in
                    Button { paint = colour } label: {
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(
                                    red: Double((colour.hex >> 16) & 0xFF) / 255,
                                    green: Double((colour.hex >> 8) & 0xFF) / 255,
                                    blue: Double(colour.hex & 0xFF) / 255))
                                .frame(width: 58, height: 58)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(paint == colour ? Color.accentColor : .white.opacity(0.35),
                                                      lineWidth: paint == colour ? 3 : 1)
                                )
                            Text(colour.name)
                                .font(.system(size: 9))
                                .lineLimit(1)
                            Text("LRV \(colour.lrv, specifier: "%.1f")")
                                .font(.system(size: 8).monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 64)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 6)
        }
        .padding(.horizontal, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
