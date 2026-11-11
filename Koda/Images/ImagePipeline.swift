import ImageIO
import KodaCore
import MediaPlayer
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Loads artwork once, at the size it is drawn.
///
/// Decoding a 544px cover for a 48pt row wastes memory a long shelf cannot
/// afford, so images are downsampled while decoding and cached per size.
/// Downloads go through `URLCache`, so a relaunch draws from disk.
actor ImagePipeline {
    static let shared = ImagePipeline()

    private let session: URLSession
    // NSCache is thread-safe; it is read without hopping onto the actor for a view's first frame.
    private nonisolated(unsafe) let memory = NSCache<NSString, PlatformImage>()
    private var inFlight: [String: Task<PlatformImage?, Never>] = [:]

    init() {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 300 << 20, directory: URL.cachesDirectory.appending(path: "artwork"))
        config.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: config)
        memory.totalCostLimit = 80 << 20
    }

    /// Bytes of artwork kept on disk.
    func diskUsage() -> Int {
        session.configuration.urlCache?.currentDiskUsage ?? 0
    }

    /// Forget every downloaded cover; they download again as they are shown.
    func clear() {
        session.configuration.urlCache?.removeAllCachedResponses()
        memory.removeAllObjects()
    }

    /// A cached image, without waiting; for the first frame of a view.
    nonisolated func cached(_ url: URL, pixels: Int) -> PlatformImage? {
        memory.object(forKey: Self.key(url, pixels) as NSString)
    }

    func image(_ url: URL, pixels: Int) async -> PlatformImage? {
        let key = Self.key(url, pixels)
        if let hit = memory.object(forKey: key as NSString) { return hit }
        if let running = inFlight[key] { return await running.value }
        let task = Task<PlatformImage?, Never> {
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return Self.downsample(data, pixels: pixels)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image {
            memory.setObject(image, forKey: key as NSString, cost: Self.cost(image))
        }
        return image
    }

    /// The request handler runs on a MediaPlayer queue, so it must not be main-actor isolated.
    nonisolated static func nowPlayingArtwork(_ image: PlatformImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
    }

    /// Bytes the decoded image holds: images are made one point per pixel.
    private nonisolated static func cost(_ image: PlatformImage) -> Int {
        Int(image.size.width * image.size.height * 4)
    }

    private static func key(_ url: URL, _ pixels: Int) -> String { "\(pixels)|\(url.absoluteString)" }

    private nonisolated static func downsample(_ data: Data, pixels: Int) -> PlatformImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return PlatformImage(cgImage: cg)
    }
}
