import UIKit
import ImageIO

/// Card-image loading, replacing `AsyncImage`.
///
/// `AsyncImage` is scoped to the view's lifetime: a `List` row that scrolls off and back
/// restarts its request, and because nothing decoded is retained, even an HTTP cache hit
/// costs a URLSession round trip plus a WebP decode — with the placeholder showing
/// throughout. On a fast network that's invisible; anywhere else it's a flash on every
/// row of every scroll.
///
/// What this adds:
///   • a decoded, downsampled image cache that a view can read **synchronously**, so a
///     card you've already seen renders in the first frame with no placeholder at all;
///   • an HTTP cache actually sized for the workload (card art is `immutable,
///     max-age=1y`, so a card fetched once should never be fetched again);
///   • request coalescing, because the same URL is asked for by many rows at once;
///   • prefetching, so the bytes are in flight before the row is on screen.
///
/// See docs/performance.md for the measurements behind this.
actor CardImageLoader {
    static let shared = CardImageLoader()

    /// Decoded + downsampled images, keyed by URL and target size. `NSCache` evicts
    /// under memory pressure on its own, which is what we want for bitmaps.
    private static let decoded: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 64 * 1024 * 1024   // bytes of bitmap, not image count
        return c
    }()

    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let session: URLSession

    /// Captured once at launch: decoding runs off the main actor and so can't read
    /// `UIScreen`. 3 is the safe default — over-decoding slightly beats a soft image.
    nonisolated(unsafe) private static var displayScale: CGFloat = 3

    @MainActor static func configure() {
        displayScale = UIScreen.main.scale
    }

    private init() {
        // Card art is immutable for a year and thumbnails are ~11 KB, so a generous
        // cache is both cheap and highly effective. The system default is small enough
        // that scrolling a collection evicts its own working set.
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 32 * 1024 * 1024,
                                   diskCapacity: 256 * 1024 * 1024,
                                   diskPath: "card-images")
        config.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: config)
    }

    /// A cached decoded image, or nil. Cheap and synchronous — this is what lets a view
    /// render known art immediately instead of flashing a placeholder.
    nonisolated static func cached(_ url: URL, size: CGSize) -> UIImage? {
        decoded.object(forKey: key(url, size) as NSString)
    }

    /// Load and decode, coalescing concurrent requests for the same URL + size.
    func image(for url: URL, size: CGSize) async -> UIImage? {
        let k = Self.key(url, size)
        if let hit = Self.decoded.object(forKey: k as NSString) { return hit }
        if let running = inFlight[k] { return await running.value }

        let task = Task<UIImage?, Never> { [session] in
            guard let data = try? await session.data(from: url).0,
                  let image = Self.downsample(data, to: size) else { return nil }
            Self.decoded.setObject(image, forKey: k as NSString, cost: Self.cost(image))
            return image
        }
        inFlight[k] = task
        let image = await task.value
        inFlight[k] = nil
        return image
    }

    /// Warm the cache for images about to scroll into view. Fire-and-forget: it shares
    /// the coalescing map, so a prefetch already running is what a visible row awaits
    /// rather than duplicating.
    func prefetch(_ urls: [URL], size: CGSize) {
        for url in urls where Self.decoded.object(forKey: Self.key(url, size) as NSString) == nil {
            guard inFlight[Self.key(url, size)] == nil else { continue }
            Task(priority: .utility) { _ = await self.image(for: url, size: size) }
        }
    }

    // MARK: -

    private static func key(_ url: URL, _ size: CGSize) -> String {
        "\(url.absoluteString)|\(Int(size.width))x\(Int(size.height))"
    }

    private static func cost(_ image: UIImage) -> Int {
        Int(image.size.width * image.size.height * image.scale * image.scale * 4)
    }

    /// Decode straight to the size we'll draw at. A 40×56 thumbnail otherwise holds a
    /// full-resolution bitmap, and this does the work off the main thread.
    private static func downsample(_ data: Data, to size: CGSize) -> UIImage? {
        let scale = displayScale
        let maxPixels = Int(max(size.width, size.height) * scale)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cg, scale: scale, orientation: .up)
    }
}
