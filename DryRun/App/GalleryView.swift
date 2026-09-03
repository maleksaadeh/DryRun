import SwiftUI

/// Saved stills, browsed with the AR session stopped.
struct GalleryView: View {

    let store: CaptureStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDeleteAll = false
    /// Capture the grid was tapped on; drives the paged destination.
    @State private var opened: Capture?

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 3)]

    var body: some View {
        NavigationStack {
            Group {
                if store.captures.isEmpty { empty } else { grid }
            }
            .navigationTitle("Captures")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !store.captures.isEmpty {
                        Button("Delete All", systemImage: "trash") {
                            confirmingDeleteAll = true
                        }
                        .labelStyle(.iconOnly)
                        .tint(.red)
                    }
                }
            }
            .confirmationDialog("Delete all \(store.captures.count) captures?",
                                isPresented: $confirmingDeleteAll,
                                titleVisibility: .visible) {
                Button("Delete All", role: .destructive) { store.deleteAll() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("No Captures", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("Paint a wall, then press the shutter to save what is on screen.")
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(store.captures) { capture in
                    Button {
                        opened = capture
                    } label: {
                        tile(for: capture)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
        }
        .navigationDestination(item: $opened) { capture in
            CapturePagerView(store: store, startingAt: capture)
        }
    }

    private func tile(for capture: Capture) -> some View {
        Group {
            if let thumbnail = store.thumbnail(for: capture) {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(height: 110)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// One capture, with the render conditions that produced it.
struct CaptureDetailView: View {

    let capture: Capture
    let store: CaptureStore

    var body: some View {
        VStack(spacing: 0) {
            if let image = store.image(for: capture) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Image missing", systemImage: "exclamationmark.triangle")
            }
            conditions
        }
    }

    private var conditions: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(capture.paintName).font(.subheadline.weight(.semibold))
                // Empty for the built-ins: an empty `Text` still takes the HStack's spacing.
                if !capture.paintCode.isEmpty {
                    Text(capture.paintCode).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Text("LRV \(capture.paintLRV, specifier: "%.1f")")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            if let detailLine {
                Text(detailLine)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Text(capture.formattedDate)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial)
    }

    private var detailLine: String? {
        guard capture.zoom > 1.01 || capture.zoom < 0.99 else { return nil }
        return String(format: "%.1f× zoom", capture.zoom)
    }
}

/// Swipeable stack of captures.
///
/// Paged by `Capture.id` rather than index, since a delete mutates the array.
struct CapturePagerView: View {

    let store: CaptureStore
    @State private var selection: UUID
    @Environment(\.dismiss) private var dismiss

    init(store: CaptureStore, startingAt capture: Capture) {
        self.store = store
        _selection = State(initialValue: capture.id)
    }

    private var current: Capture? {
        store.captures.first { $0.id == selection }
    }

    private var position: (index: Int, total: Int)? {
        guard let index = store.captures.firstIndex(where: { $0.id == selection }) else { return nil }
        return (index + 1, store.captures.count)
    }

    var body: some View {
        TabView(selection: $selection) {
            ForEach(store.captures) { capture in
                CaptureDetailView(capture: capture, store: store)
                    .tag(capture.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .navigationTitle(position.map { "\($0.index) of \($0.total)" } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let current, let image = store.image(for: current) {
                    ShareLink(item: Image(uiImage: image),
                              preview: SharePreview(current.paintName, image: Image(uiImage: image)))
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Delete", systemImage: "trash") { deleteCurrent() }
                    .labelStyle(.iconOnly)
                    .tint(.red)
                    .disabled(current == nil)
            }
        }
    }

    /// Deletes the visible capture and stays put, moving to a neighbour rather than closing.
    private func deleteCurrent() {
        guard let current,
              let index = store.captures.firstIndex(where: { $0.id == current.id }) else { return }

        // Resolve the successor before mutating, since the index is about to mean something else.
        let successor = store.captures.indices.contains(index + 1)
            ? store.captures[index + 1]
            : (index > 0 ? store.captures[index - 1] : nil)

        store.delete(current)

        if let successor {
            selection = successor.id
        } else {
            dismiss()
        }
    }
}
