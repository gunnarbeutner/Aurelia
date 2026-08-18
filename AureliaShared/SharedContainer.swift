//
//  SharedContainer.swift
//  AureliaShared
//
//  App group storage the widget extension reads now-playing state from
//

import Foundation
import os

#if canImport(UIKit)
import UIKit
#endif

/// The app group both processes mount. Everything the widget draws lives here,
/// because an extension cannot reach into the app's own container.
nonisolated enum SharedContainer {
    static let appGroupIdentifier = "group.de.beutner.Aurelia"

    private static let logger = Logger(subsystem: "de.beutner.Aurelia", category: "SharedContainer")

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    private static var snapshotURL: URL? {
        containerURL?.appendingPathComponent("now-playing.json", isDirectory: false)
    }

    static var artworkDirectoryURL: URL? {
        containerURL?.appendingPathComponent("NowPlayingArtwork", isDirectory: true)
    }

    // MARK: - Snapshot

    static func loadSnapshot() -> NowPlayingSnapshot? {
        guard let snapshotURL, let data = try? Data(contentsOf: snapshotURL) else { return nil }
        return try? JSONDecoder().decode(NowPlayingSnapshot.self, from: data)
    }

    static func save(_ snapshot: NowPlayingSnapshot) {
        guard let snapshotURL else { return }
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: snapshotURL, options: .atomic)
        } catch {
            logger.error("Failed to write now-playing snapshot: \(error.localizedDescription)")
        }
    }

    static func clearSnapshot() {
        guard let snapshotURL else { return }
        try? FileManager.default.removeItem(at: snapshotURL)
    }

    // MARK: - Artwork

    static func artworkURL(named fileName: String) -> URL? {
        artworkDirectoryURL?.appendingPathComponent(fileName, isDirectory: false)
    }

#if canImport(UIKit)
    /// Longest edge of the exported PNG. Large enough for the system medium
    /// family on a 3x screen, small enough to rewrite on every track change.
    static let artworkPixelSize: CGFloat = 512

    /// Writes `image` into the shared container and returns the file name to
    /// put in the snapshot. The name carries the track id so a widget reading
    /// mid-write cannot pick up the previous track's file under a shared name.
    @discardableResult
    static func writeArtwork(_ image: UIImage, forTrackID trackID: String) -> String? {
        guard let artworkDirectoryURL else { return nil }

        let fileName = "\(trackID).png"
        let destination = artworkDirectoryURL.appendingPathComponent(fileName, isDirectory: false)

        do {
            try FileManager.default.createDirectory(at: artworkDirectoryURL, withIntermediateDirectories: true)
            guard let data = downscaled(image).pngData() else { return nil }
            try data.write(to: destination, options: .atomic)
        } catch {
            logger.error("Failed to write shared artwork: \(error.localizedDescription)")
            return nil
        }

        pruneArtwork(keeping: fileName)
        return fileName
    }

    /// Only the current track's artwork is ever read, so everything else is
    /// dead weight in a container the user cannot clear themselves.
    static func pruneArtwork(keeping fileName: String?) {
        guard let artworkDirectoryURL else { return }
        let contents = try? FileManager.default.contentsOfDirectory(
            at: artworkDirectoryURL,
            includingPropertiesForKeys: nil
        )
        for url in contents ?? [] where url.lastPathComponent != fileName {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func downscaled(_ image: UIImage) -> UIImage {
        let longestEdge = max(image.size.width, image.size.height)
        guard longestEdge > artworkPixelSize else { return image }

        let scale = artworkPixelSize / longestEdge
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
#endif
}
