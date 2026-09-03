import Foundation

/// A saved still, and the paint that produced it.
struct Capture: Identifiable, Codable, Hashable {

    let id: UUID
    let createdAt: Date

    /// Paint applied at capture time.
    let paintName: String
    let paintCode: String
    let paintLRV: Float

    /// Digital zoom at capture time.
    let zoom: Float

    var imageFile: String { "\(id.uuidString).jpg" }
    var thumbnailFile: String { "\(id.uuidString)-thumb.jpg" }

    var formattedDate: String {
        Capture.dateFormatter.string(from: createdAt)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
