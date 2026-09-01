import CoreGraphics
import Foundation
import ImageIO
import Observation
import UIKit
import UniformTypeIdentifiers

/// On-disk library of saved stills.
///
/// Plain files under Documents — a JSON index beside one JPEG and one thumbnail per capture —
/// rather than SwiftData or Core Data. Being able to pull the folder off the device with Finder
/// and read the index in a text editor is worth more here than a query language, and there is no
/// relational shape to model.
@MainActor
@Observable
final class CaptureStore {

    /// Newest first.
    private(set) var captures: [Capture] = []

    private let directory: URL
    private let indexURL: URL
    private let thumbnailCache = NSCache<NSString, UIImage>()
    /// Full-size decode cache. Paging holds neighbours alive and re-evaluates bodies freely, so
    /// without this a swipe re-decodes multi-megapixel JPEGs on every pass. Bounded because these
    /// are full-resolution stills and an unbounded cache would grow to the size of the library.
    private let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 6
        return cache
    }()

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = documents.appending(path: "Captures")
        indexURL = directory.appending(path: "index.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    // MARK: - Reading

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let stored = try? decoder.decode([Capture].self, from: data) else { return }
        captures = stored.sorted { $0.createdAt > $1.createdAt }
    }

    func url(for filename: String) -> URL {
        directory.appending(path: filename)
    }

    func image(for capture: Capture) -> UIImage? {
        let key = capture.imageFile as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        guard let image = UIImage(contentsOfFile: url(for: capture.imageFile).path()) else {
            return nil
        }
        imageCache.setObject(image, forKey: key)
        return image
    }

    /// Cached, because a grid scroll would otherwise decode the same JPEGs repeatedly.
    func thumbnail(for capture: Capture) -> UIImage? {
        let key = capture.thumbnailFile as NSString
        if let cached = thumbnailCache.object(forKey: key) { return cached }
        guard let image = UIImage(contentsOfFile: url(for: capture.thumbnailFile).path()) else {
            return nil
        }
        thumbnailCache.setObject(image, forKey: key)
        return image
    }

    // MARK: - Writing

    @discardableResult
    func save(_ image: CGImage, describing capture: Capture) -> Bool {
        let uiImage = UIImage(cgImage: image)
        // 0.95: this is the record of a colour judgement, so chroma subsampling artefacts are
        // worth avoiding even at the cost of file size.
        guard let data = uiImage.jpegData(compressionQuality: 0.95),
              let thumbnail = Self.thumbnail(from: uiImage)?.jpegData(compressionQuality: 0.8)
        else { return false }

        do {
            try data.write(to: url(for: capture.imageFile))
            try thumbnail.write(to: url(for: capture.thumbnailFile))
        } catch {
            return false
        }

        captures.insert(capture, at: 0)
        writeIndex()
        return true
    }

    func delete(_ capture: Capture) {
        for file in [capture.imageFile, capture.thumbnailFile] {
            try? FileManager.default.removeItem(at: url(for: file))
        }
        thumbnailCache.removeObject(forKey: capture.thumbnailFile as NSString)
        imageCache.removeObject(forKey: capture.imageFile as NSString)
        captures.removeAll { $0.id == capture.id }
        writeIndex()
    }

    func deleteAll() {
        for capture in captures {
            for file in [capture.imageFile, capture.thumbnailFile] {
                try? FileManager.default.removeItem(at: url(for: file))
            }
        }
        thumbnailCache.removeAllObjects()
        imageCache.removeAllObjects()
        captures.removeAll()
        writeIndex()
    }

    private func writeIndex() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(captures) else { return }
        try? data.write(to: indexURL)
    }

    private static func thumbnail(from image: UIImage, maxEdge: CGFloat = 480) -> UIImage? {
        let scale = min(maxEdge / image.size.width, maxEdge / image.size.height, 1)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
