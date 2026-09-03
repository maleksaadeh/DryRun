import SwiftUI
import Metal

/// The camera screen: point at a wall, tap it, pick a colour.
struct ContentView: View {
    @StateObject private var controller: ARSessionController
    @StateObject private var calibration = CaptureCalibration()
    private let renderer: WallRenderer

    @State private var paint = PaintCatalog.default
    @State private var detailGain: Float = 0.6
    @State private var occluderBounds = OccluderBounds.default
    @State private var showsControls = true
    /// Digital zoom, and the value it had when the current pinch began.
    @State private var zoom: Float = 1
    @State private var zoomAtGestureStart: Float = 1
    @State private var store = CaptureStore()
    @State private var customColours = CustomPaintStore()
    @State private var entitlements = Entitlements()
    @State private var isAddingColour = false
    @State private var editingColour: PaintColor?
    @State private var showsGallery = false
    /// Bumped once per shutter press; the renderer captures one frame per distinct value.
    @State private var captureToken = 0
    /// True from the press until the still has been written, to keep the shutter from re-firing.
    @State private var isCapturing = false
    @State private var captureNote: String?

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
                       isPaintLocked: isPaintLocked,
                       captureToken: captureToken,
                       onCapture: handleCapture)
                .ignoresSafeArea()
                // Takes no touches: a full-screen hit target competes with the controls above it.
                .allowsHitTesting(false)

            GeometryReader { geometry in
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { location in
                        // Portrait-locked in Info.plist, so the orientation is fixed.
                        controller.selectWall(at: location,
                                              viewportSize: geometry.size,
                                              orientation: .portrait)
                    }
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
        .sheet(isPresented: $isAddingColour) {
            CustomColorForm(store: customColours)
        }
        .sheet(item: $editingColour) { colour in
            CustomColorForm(existing: colour, store: customColours)
        }
        .onChange(of: customColours.colours) { _, colours in
            if paint.isCustom, !colours.contains(where: { $0.id == paint.id }) {
                paint = PaintCatalog.default
            }
        }
        .onChange(of: showsGallery) { _, isShowing in
            // Nothing to render behind an opaque screen.
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
    private var prompt: String? {
        if isPaintLocked { return "Unlock custom colours to see this one on your wall." }
        if let note = controller.trackingNote { return note }
        if controller.selectedWallID == nil { return controller.status }
        return nil
    }

    /// Whether the selected colour is withheld from the wall pending purchase.
    private var isPaintLocked: Bool { paint.isCustom && !entitlements.isUnlocked }

    /// Upper zoom limit. This is a crop, not a lens.
    static let maximumZoom: Float = 3

    /// Lower zoom limit: the point where the entire captured frame is on screen.
    ///
    /// `ARFrame.displayTransform` aspect-*fills*, and aspect-fill shows `min(a, b) / max(a, b)` of
    /// the source, which is exactly the zoom at which nothing is cropped.
    private func minimumZoom(viewport: CGSize) -> Float {
        guard let cameraAspect = controller.cameraAspect,
              cameraAspect > 0, viewport.width > 0, viewport.height > 0 else { return 1 }
        let viewportAspect = Float(viewport.width / viewport.height)
        let fit = min(viewportAspect, cameraAspect) / max(viewportAspect, cameraAspect)
        // Guard against a format that needs no crop at all, which would otherwise allow 1x only.
        return min(fit, 1)
    }

    /// Reset and show/hide, pinned top-trailing.
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
        #if targetEnvironment(simulator)
        // No ARFrame means the token is never serviced, so `isCapturing` would never clear.
        show("No camera in the Simulator.")
        #else
        isCapturing = true
        captureToken += 1
        #endif
    }

    /// Files the frame the renderer handed back.
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
    private var surfaceControl: some View {
        VStack(alignment: .leading, spacing: 9) {
            selectedPaint

            Divider().overlay(.white.opacity(0.15))

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

                Toggle(isOn: $controller.excludesOpenings) {
                    Text("Exclude doors & windows")
                        .font(.caption.weight(.medium))
                }
                .toggleStyle(.switch)
                .tint(.white)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var selectedPaint: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(paint: paint))
                .frame(width: 22, height: 22)
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(.white.opacity(0.3), lineWidth: 1)
                }
            Text(paint.name)
                .font(.subheadline.weight(.semibold))
            // Custom colours may have no code.
            if !paint.code.isEmpty {
                Text(paint.code)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            if isPaintLocked {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Locked")
            }
            Spacer(minLength: 4)
            Text("LRV \(paint.lrv, specifier: "%.1f")")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    /// Plain-language stand-in for the slider's raw metres.
    private var surfaceDepthLabel: String {
        switch occluderBounds.band {
        case ..<0.015: "Tight"
        case ..<0.035: "Balanced"
        default:       "Loose"
        }
    }

    private var palette: [PaintColor] { PaintCatalog.featured + customColours.colours }

    private var swatches: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(palette) { colour in
                    swatch(for: colour)
                }
                addSwatch
            }
            .padding(.vertical, 6)
        }
        .padding(.horizontal, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    /// One chip. Custom colours additionally carry a long-press menu to edit or delete them.
    @ViewBuilder
    private func swatch(for colour: PaintColor) -> some View {
        let button = Button { paint = colour } label: { chip(for: colour) }
            .buttonStyle(.plain)

        if colour.isCustom {
            button.contextMenu {
                Button { editingColour = colour } label: { Label("Edit", systemImage: "pencil") }
                Button(role: .destructive) {
                    customColours.delete(colour)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        } else {
            button
        }
    }

    private func chip(for colour: PaintColor) -> some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(paint: colour))
                .frame(width: 58, height: 58)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(paint == colour ? Color.accentColor : .white.opacity(0.35),
                                      lineWidth: paint == colour ? 3 : 1)
                )
                .overlay(alignment: .topTrailing) {
                    if colour.isCustom, !entitlements.isUnlocked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(.black.opacity(0.55), in: Circle())
                            .padding(3)
                    }
                }
            Text(colour.name)
                .font(.system(size: 9))
                .lineLimit(1)
            Text("LRV \(colour.lrv, specifier: "%.1f")")
                .font(.system(size: 8).monospaced())
                .foregroundStyle(.secondary)
        }
        .frame(width: 64)
    }

    private var addSwatch: some View {
        Button { isAddingColour = true } label: {
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.white.opacity(0.45),
                                  style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .frame(width: 58, height: 58)
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 20, weight: .medium))
                    }
                Text("Add")
                    .font(.system(size: 9))
                Text("custom")
                    .font(.system(size: 8).monospaced())
                    .foregroundStyle(.secondary)
            }
            .frame(width: 64)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add a custom colour")
    }
}
