//
//  ImageCache.swift
//  Aurelia
//
//  Actor-based image cache with memory + disk layers
//

import UIKit
import os.log

/// Whether a URL's bytes hold more than one frame, once anything has looked.
///
/// Kept off the actor so a view can answer "this is an ordinary still I already
/// have" without suspending: a shelf of covers scrolling into view would
/// otherwise queue a disk read and a decode each, behind a single actor.
private final class AnimationVerdicts: @unchecked Sendable {
    nonisolated(unsafe) private let verdicts: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 4000
        return cache
    }()

    nonisolated init() {}

    nonisolated func isAnimated(_ key: String) -> Bool? {
        verdicts.object(forKey: key as NSString)?.boolValue
    }

    nonisolated func record(_ animated: Bool, for key: String) {
        verdicts.setObject(NSNumber(value: animated), forKey: key as NSString)
    }
}

private final class MemoryImageCache: @unchecked Sendable {
    nonisolated(unsafe) private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 100 * 1024 * 1024
        cache.countLimit = 300
        return cache
    }()

    nonisolated init() {}

    nonisolated func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    nonisolated func insert(_ image: UIImage, for key: String, cost: Int) {
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }
}

actor ImageCache {
    static let shared = ImageCache()

    private let logger = Logger(subsystem: "de.beutner.Aurelia", category: "ImageCache")

    // MARK: - Memory Cache
    nonisolated private let memoryCache = MemoryImageCache()
    nonisolated private let animationVerdicts = AnimationVerdicts()

    // MARK: - Disk Cache
    private let diskCacheURL: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("ImageCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private let maxDiskBytes: UInt64 = 500 * 1024 * 1024 // 500MB
    private let diskExpiry: TimeInterval = 7 * 24 * 3600 // 7 days

    // MARK: - URL Session
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = nil // We manage our own cache
        return URLSession(configuration: config)
    }()

    // MARK: - Public API

    /// Context-menu previews are recreated synchronously. Giving them direct
    /// access to the thread-safe memory layer prevents an empty-to-loaded state
    /// transition from replacing the preview while its menu is opening.
    nonisolated func cachedMemoryImage(for url: URL) -> UIImage? {
        memoryCache.image(for: Self.cacheKey(for: url))
    }

    nonisolated func cacheMemoryImage(_ image: UIImage, for url: URL, cost: Int = 0) {
        memoryCache.insert(image, for: Self.cacheKey(for: url), cost: cost)
    }

    /// Get image from cache (memory → disk) or nil
    func cachedImage(for url: URL) -> UIImage? {
        let key = Self.cacheKey(for: url)

        // Memory
        if let img = memoryCache.image(for: key) {
            return img
        }

        // Disk
        let filePath = diskCacheURL.appendingPathComponent(key)
        guard FileManager.default.fileExists(atPath: filePath.path) else { return nil }

        // Check expiry
        if let attrs = try? FileManager.default.attributesOfItem(atPath: filePath.path),
           let modDate = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modDate) > diskExpiry {
            try? FileManager.default.removeItem(at: filePath)
            return nil
        }

        guard let data = try? Data(contentsOf: filePath),
              let img = UIImage(data: data) else { return nil }

        // Promote to memory
        let cost = data.count
        cacheMemoryImage(img, for: url, cost: cost)
        return img
    }

    /// Download image, cache it, return it
    func loadImage(from url: URL) async throws -> UIImage {
        // Check cache first
        if let cached = cachedImage(for: url) {
            return cached
        }

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let img = UIImage(data: data) else {
            throw URLError(.badServerResponse)
        }

        let key = Self.cacheKey(for: url)

        // Memory
        cacheMemoryImage(img, for: url, cost: data.count)

        // Disk (fire and forget)
        let filePath = diskCacheURL.appendingPathComponent(key)
        try? data.write(to: filePath)

        return img
    }

    /// Artwork prepared for display, animated or not.
    ///
    /// The still case carries a decoded frame, since that is the common one and
    /// decoding it here keeps it off the main thread. The animated case carries
    /// the encoded bytes, because animation only exists while the data is still
    /// encoded — `UIImage` keeps the first frame and discards the rest.
    enum Artwork: Sendable {
        case still(UIImage)
        case animated(Data)
    }

    func artwork(from url: URL) async throws -> Artwork {
        let key = Self.cacheKey(for: url)
        if let image = stillImageIfKnown(for: url) {
            return .still(image)
        }

        let data = try await imageData(from: url)

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 1 else {
            guard let image = UIImage(data: data) else { throw URLError(.cannotDecodeContentData) }
            animationVerdicts.record(false, for: key)
            cacheMemoryImage(image, for: url, cost: data.count)
            return .still(image)
        }

        animationVerdicts.record(true, for: key)
        return .animated(data)
    }

    /// A decoded image for a URL already known to hold a single frame, if it is
    /// still in memory. Answers without suspending, so a view can take the
    /// ordinary path without touching the disk or this actor.
    nonisolated func stillImageIfKnown(for url: URL) -> UIImage? {
        let key = Self.cacheKey(for: url)
        guard animationVerdicts.isAnimated(key) == false else { return nil }
        return memoryCache.image(for: key)
    }

    /// The encoded bytes for a URL, rather than a decoded image.
    func imageData(from url: URL) async throws -> Data {
        let key = Self.cacheKey(for: url)
        let filePath = diskCacheURL.appendingPathComponent(key)

        if let data = try? Data(contentsOf: filePath), !data.isEmpty {
            return data
        }

        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        try? data.write(to: filePath)
        if let image = UIImage(data: data) {
            cacheMemoryImage(image, for: url, cost: data.count)
        }
        return data
    }

    // MARK: - Helpers

    nonisolated private static func cacheKey(for url: URL) -> String {
        // SHA256-like hash using simple approach
        let str = url.absoluteString
        var hash: UInt64 = 5381
        for byte in str.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }

    /// Evict expired disk entries (call occasionally)
    func evictExpired() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: diskCacheURL, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return }

        for file in files {
            if let attrs = try? fm.attributesOfItem(atPath: file.path),
               let modDate = attrs[.modificationDate] as? Date,
               Date().timeIntervalSince(modDate) > diskExpiry {
                try? fm.removeItem(at: file)
            }
        }
    }
}
