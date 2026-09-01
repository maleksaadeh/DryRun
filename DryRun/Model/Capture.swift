import Foundation

/// A saved still, and the paint that produced it.
///
/// The paint is stored alongside the image because the pixels alone cannot answer "which colour
/// was this?" — two colours a few LRV points apart are indistinguishable on screen once the
/// wall's own shading is folded in, which is precisely the case someone comparing captures is
/// trying to decide between.
struct Capture: Identifiable, Codable, Hashable {

    let id: UUID
    let createdAt: Date

    /// Paint applied at capture time.
    let paintName: String
    let paintCode: String
    let paintLRV: Float

    /// Digital zoom. Recorded because sharpness in the still is a crop artefact, not a lens one.
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
