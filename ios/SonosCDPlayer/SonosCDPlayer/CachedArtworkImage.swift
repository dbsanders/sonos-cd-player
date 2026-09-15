import CryptoKit
import Foundation
import ImageIO
import SwiftUI
import UIKit

enum AlbumArtwork {
    private static let sonosBaseURL = URL(string: "http://192.168.1.85:1400")!

    static func url(for path: String?) -> URL? {
        path.flatMap { URL(string: $0, relativeTo: sonosBaseURL) }
    }

    /// Warms the persistent cache without requiring any artwork views to appear.
    static func prefetch(_ paths: [String?]) async {
        var seen = Set<URL>()
        let urls = paths.compactMap(url(for:)).filter { seen.insert($0).inserted }
        var iterator = urls.makeIterator()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<min(4, urls.count) {
                guard let url = iterator.next() else { break }
                group.addTask { await AlbumArtworkCache.shared.prefetch(url) }
            }

            while await group.next() != nil {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    break
                }
                if let url = iterator.next() {
                    group.addTask { await AlbumArtworkCache.shared.prefetch(url) }
                }
            }
        }
    }
}

/// Album artwork with a small memory cache and a persistent, size-limited disk cache.
/// Images are downsampled before caching so large source files never accumulate in memory.
struct CachedArtworkImage<Placeholder: View>: View {
    let url: URL?
    let placeholder: () -> Placeholder

    @State private var image: UIImage?

    init(url: URL?, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable()
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            image = nil
            guard let url else { return }
            image = try? await AlbumArtworkCache.shared.image(for: url)
        }
    }
}

private actor AlbumArtworkCache {
    static let shared = AlbumArtworkCache()

    private let memoryCache = NSCache<NSURL, UIImage>()
    private let fileManager = FileManager.default
    private let diskLimit = 200 * 1_024 * 1_024
    private let maximumPixelSize = 512
    private let directory: URL

    init() {
        let manager = FileManager.default
        let caches = manager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("AlbumArtwork-v1", isDirectory: true)
        memoryCache.totalCostLimit = 32 * 1_024 * 1_024
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func image(for url: URL) async throws -> UIImage {
        if let cached = memoryCache.object(forKey: url as NSURL) {
            return cached
        }

        let file = directory.appendingPathComponent(cacheKey(for: url))
        if let data = try? Data(contentsOf: file), let cached = UIImage(data: data) {
            memoryCache.setObject(cached, forKey: url as NSURL, cost: memoryCost(of: cached))
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            return cached
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            throw URLError(.badServerResponse)
        }
        try Task.checkCancellation()

        guard let decoded = downsample(data) else { throw URLError(.cannotDecodeContentData) }
        memoryCache.setObject(decoded, forKey: url as NSURL, cost: memoryCost(of: decoded))

        if let encoded = decoded.jpegData(compressionQuality: 0.82) {
            try? encoded.write(to: file, options: .atomic)
            trimDiskCacheIfNeeded()
        }
        return decoded
    }

    func prefetch(_ url: URL) async {
        guard memoryCache.object(forKey: url as NSURL) == nil else { return }
        let file = directory.appendingPathComponent(cacheKey(for: url))
        guard !fileManager.fileExists(atPath: file.path) else { return }
        _ = try? await image(for: url)
    }

    private func downsample(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    private func cacheKey(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined() + ".jpg"
    }

    private func memoryCost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }

    private func trimDiskCacheIfNeeded() {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) else { return }
        let entries = files.compactMap { file -> (URL, Int, Date)? in
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
            return (file, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        guard total > diskLimit else { return }
        for entry in entries.sorted(by: { $0.2 < $1.2 }) {
            try? fileManager.removeItem(at: entry.0)
            total -= entry.1
            if total <= diskLimit { break }
        }
    }
}
