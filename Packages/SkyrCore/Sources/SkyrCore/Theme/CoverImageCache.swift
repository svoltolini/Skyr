import CoreGraphics
import Foundation
import ImageIO

/// Decoded covers kept in memory, so cards show their artwork on first layout instead of flashing
/// the gradient placeholder every time a shelf or list is rebuilt. `CGImage` is the one image type
/// every Apple platform shares, so the same cache serves iPhone, Mac and the rest.
public final class CoverImageCache {
    public static let shared = CoverImageCache()
    public static let rowPixels = 192
    public static let thumbnailPixels = 512
    public static let largePixels = 1200

    private let cache = NSCache<NSString, CGImage>()
    private var inFlight: [String: Task<CGImage?, Never>] = [:]

    init() { cache.totalCostLimit = 96 * 1024 * 1024 }

    public func cached(_ key: String) -> CGImage? { cache.object(forKey: key as NSString) }

    public func image(url: URL, key: String, maxPixelSize: Int) async -> CGImage? {
        if let hit = cached(key) { return hit }
        if let task = inFlight[key] { return await task.value }
        let task = Task.detached(priority: .userInitiated) { Self.decode(url: url, maxPixelSize: maxPixelSize) }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image {
            cache.setObject(image, forKey: key as NSString, cost: image.width * image.height * 4)
        }
        return image
    }

    public func removeAll() { cache.removeAllObjects() }

    public nonisolated static func decode(url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
