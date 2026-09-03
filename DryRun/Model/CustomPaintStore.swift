import Foundation
import Observation

/// Colours the user has entered, persisted as JSON under Documents.
@MainActor
@Observable
final class CustomPaintStore {

    /// Oldest first, so the swatch row does not reshuffle when one is edited.
    private(set) var colours: [PaintColor] = []

    private let fileURL: URL

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = documents.appending(path: "custom-colours.json")
        load()
    }

    // MARK: - Reading

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([PaintColor].self, from: data) else { return }
        // Force the flag on read rather than trusting the file: it drives the paid gate.
        colours = stored.map { colour in
            var owned = colour
            owned.isCustom = true
            return owned
        }
    }

    // MARK: - Writing

    /// Adds a colour, or replaces the existing one with the same id.
    func save(_ colour: PaintColor) {
        var stored = colour
        stored.isCustom = true
        if let index = colours.firstIndex(where: { $0.id == stored.id }) {
            colours[index] = stored
        } else {
            colours.append(stored)
        }
        write()
    }

    func delete(_ colour: PaintColor) {
        colours.removeAll { $0.id == colour.id }
        write()
    }

    /// Whether a name is already taken, ignoring one colour being edited.
    func isNameTaken(_ name: String, excluding id: String?) -> Bool {
        let candidate = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return colours.contains { $0.id != id && $0.name.lowercased() == candidate }
    }

    private func write() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(colours) else { return }
        try? data.write(to: fileURL)
    }
}
