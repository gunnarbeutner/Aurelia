//
//  DownloadManager.swift
//  Aurelia
//
//  Manages offline downloads for tracks and albums
//  Stores audio files locally for offline playback
//

import Foundation
import Combine
import os.log
import UserNotifications
import UIKit

/// Download state for a track
enum DownloadState: Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case downloaded
    case failed(error: String)

    var isDownloaded: Bool {
        if case .downloaded = self {
            return true
        }
        return false
    }

    var isDownloading: Bool {
        if case .downloading = self {
            return true
        }
        return false
    }
}

/// How much of the original file to keep when downloading.
///
/// Deliberately separate from `StreamingQuality`: a stream is disposable and
/// bandwidth-bound, while a download is permanent and storage-bound, and a
/// library that fits on the device at one setting will not at the other.
nonisolated enum DownloadQuality: String, Codable, Sendable, CaseIterable, Identifiable {
    case low
    case medium
    case high
    /// The file exactly as the server holds it. The default: silently
    /// degrading music someone already has is not a thing a default should do.
    case original

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .low: return "Small"
        case .medium: return "Medium"
        case .high: return "High"
        case .original: return "Original"
        }
    }

    /// kbps, or zero when the file is taken as-is.
    var bitrate: Int {
        switch self {
        case .low: return 128
        case .medium: return 192
        case .high: return 320
        case .original: return 0
        }
    }

    var description: String {
        switch self {
        case .low: return "128 kbps — about 58 MB per hour"
        case .medium: return "192 kbps — about 86 MB per hour"
        case .high: return "320 kbps — about 144 MB per hour"
        case .original: return "Exactly what is on the server, however large"
        }
    }

    /// Bytes of file per second of audio. Known exactly for a transcode, and
    /// only measurable for the original, whose size depends on the source.
    var bytesPerSecond: Double? {
        guard self != .original else { return nil }
        return Double(bitrate) * 1000 / 8
    }

    /// Container the server is asked to transcode into. MP3 is what the
    /// streaming path already negotiates successfully with Jellyfin, so
    /// downloads use the same rather than introducing an untested format.
    var fileExtension: String? {
        self == .original ? nil : "mp3"
    }
}

/// Metadata for a downloaded track
nonisolated struct DownloadedTrack: Codable, Sendable, Equatable {
    let trackId: String
    let fileName: String
    let fileSize: Int64
    let downloadDate: Date
    let trackName: String
    let artistName: String
    let albumName: String
    let duration: TimeInterval?
    let albumId: String

    // Track organization metadata
    let trackNumber: Int?
    let discNumber: Int?
    let artistId: String?
    let productionYear: Int?
    let artworkURL: String? // For caching album artwork

    /// Who is holding onto this file. The file is deleted when the last owner
    /// lets go, so a hand-picked download survives the favorites rule losing
    /// interest in it, and vice versa.
    var owners: Set<DownloadOrigin>

    /// What was asked for when this file was fetched. Recorded because the
    /// setting can change afterwards, and a library that silently mixes
    /// qualities with no way to tell them apart is worse than either.
    let quality: DownloadQuality

    init(
        trackId: String,
        fileName: String,
        fileSize: Int64,
        downloadDate: Date,
        trackName: String,
        artistName: String,
        albumName: String,
        duration: TimeInterval?,
        albumId: String,
        trackNumber: Int?,
        discNumber: Int?,
        artistId: String?,
        productionYear: Int?,
        artworkURL: String?,
        owners: Set<DownloadOrigin> = [.manual],
        quality: DownloadQuality = .original
    ) {
        self.trackId = trackId
        self.fileName = fileName
        self.fileSize = fileSize
        self.downloadDate = downloadDate
        self.trackName = trackName
        self.artistName = artistName
        self.albumName = albumName
        self.duration = duration
        self.albumId = albumId
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.artistId = artistId
        self.productionYear = productionYear
        self.artworkURL = artworkURL
        self.owners = owners
        self.quality = quality
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        trackId = try container.decode(String.self, forKey: .trackId)
        fileName = try container.decode(String.self, forKey: .fileName)
        fileSize = try container.decode(Int64.self, forKey: .fileSize)
        downloadDate = try container.decode(Date.self, forKey: .downloadDate)
        trackName = try container.decode(String.self, forKey: .trackName)
        artistName = try container.decode(String.self, forKey: .artistName)
        albumName = try container.decode(String.self, forKey: .albumName)
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration)
        albumId = try container.decode(String.self, forKey: .albumId)
        trackNumber = try container.decodeIfPresent(Int.self, forKey: .trackNumber)
        discNumber = try container.decodeIfPresent(Int.self, forKey: .discNumber)
        artistId = try container.decodeIfPresent(String.self, forKey: .artistId)
        productionYear = try container.decodeIfPresent(Int.self, forKey: .productionYear)
        artworkURL = try container.decodeIfPresent(String.self, forKey: .artworkURL)
        // Records written before downloads had owners predate the favorites
        // rule, so everything they describe was put on the device by hand.
        // Decoding them as unowned would let the first reconcile delete them.
        owners = try container.decodeIfPresent(Set<DownloadOrigin>.self, forKey: .owners) ?? [.manual]
        // Everything downloaded before quality was configurable came from the
        // /Download endpoint, which only ever served the original file.
        quality = try container.decodeIfPresent(DownloadQuality.self, forKey: .quality) ?? .original
    }

    /// Convert to Track for playback
    func toTrack() -> Track {
        return Track(
            id: trackId,
            name: trackName,
            artistName: artistName,
            albumName: albumName,
            duration: duration ?? 0,
            artworkURL: nil, // Local files don't need artwork URL
            isFavorite: false, // Can implement favorites for downloads later
            indexNumber: trackNumber,
            parentIndexNumber: discNumber,
            albumId: albumId,
            artistId: artistId,
            productionYear: productionYear
        )
    }
}

/// Represents a downloaded album with all its tracks
struct DownloadedAlbum: Identifiable {
    let albumId: String
    let albumName: String
    let artistName: String
    let artistId: String?
    let productionYear: Int?
    let tracks: [DownloadedTrack]

    var id: String { albumId }

    var trackCount: Int { tracks.count }

    var totalSize: Int64 {
        tracks.reduce(0) { $0 + $1.fileSize }
    }

    var totalDuration: TimeInterval {
        tracks.compactMap { $0.duration }.reduce(0, +)
    }

    /// Release years are identifiers, not quantities. Returning a String keeps
    /// SwiftUI from applying locale-specific thousands separators (for example
    /// rendering 2026 as "2.026").
    var productionYearText: String? {
        productionYear.map(String.init)
    }

    func toAlbum() -> Album {
        Album(
            id: albumId,
            name: albumName,
            artistName: artistName,
            artistId: artistId,
            year: productionYear,
            trackCount: trackCount,
            artworkURL: nil
        )
    }

    var formattedDuration: String {
        let totalSeconds = Int(totalDuration)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }
}

/// Why a track is not downloaded and is not going to be without help.
struct DownloadFailure: Equatable {
    let message: String
    let isPermanent: Bool
}

/// Manages downloading and storing music files for offline playback.
///
/// All mutable state is owned by the main thread. `URLSession` delegate
/// callbacks arrive on the session's own queue, so each one does only the work
/// that has to happen there — moving the finished file off the temporary
/// location — and hands the bookkeeping to main.
class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    private let logger = Logger(subsystem: "de.beutner.Aurelia", category: "DownloadManager")

    /// How many files may be in flight at once. A favorites sync can ask for
    /// thousands; handing all of them to URLSession at once buys nothing and
    /// makes progress reporting a firehose.
    private let maxConcurrentDownloads = 4

    /// Give up after this many tries and park the track in `failedDownloads`,
    /// where the UI can offer a retry.
    private let maxAttempts = 3

    // MARK: - Published Properties
    @Published var downloadStates: [String: DownloadState] = [:] // trackId -> state
    @Published var downloadedTracks: [DownloadedTrack] = []
    @Published var totalStorageUsed: Int64 = 0
    @Published var activeDownloads: Int = 0 // Number of currently downloading tracks
    @Published private(set) var queuedDownloads: Int = 0 // Waiting for a slot
    @Published private(set) var isPaused = false
    @Published private(set) var failedDownloads: [String: DownloadFailure] = [:]
    /// True when work is queued but held back because the only connection is a
    /// metered one the favorites rule is not allowed to use.
    @Published private(set) var isWaitingForWiFi = false

    /// Set by the app delegate when the system wakes the app to report that a
    /// background session finished while it was not running.
    var backgroundCompletionHandler: (() -> Void)?

    // MARK: - Computed Properties for Organization

    /// Downloaded tracks grouped by album, sorted by track order
    var downloadedAlbums: [DownloadedAlbum] {
        let grouped = Dictionary(grouping: downloadedTracks) { $0.albumId }

        return grouped.map { albumId, tracks in
            let sortedTracks = tracks.sorted { track1, track2 in
                // Sort by disc number first, then track number
                let disc1 = track1.discNumber ?? 1
                let disc2 = track2.discNumber ?? 1

                if disc1 != disc2 {
                    return disc1 < disc2
                }

                let track1Num = track1.trackNumber ?? 0
                let track2Num = track2.trackNumber ?? 0
                return track1Num < track2Num
            }

            // Use metadata from first track for album info
            let firstTrack = sortedTracks.first!
            return DownloadedAlbum(
                albumId: albumId,
                albumName: firstTrack.albumName,
                artistName: firstTrack.artistName,
                artistId: firstTrack.artistId,
                productionYear: firstTrack.productionYear,
                tracks: sortedTracks
            )
        }.sorted { album1, album2 in
            // Sort albums by year (newest first), then name
            if let year1 = album1.productionYear, let year2 = album2.productionYear, year1 != year2 {
                return year1 > year2
            }
            return album1.albumName < album2.albumName
        }
    }

    /// Total number of downloaded albums
    var downloadedAlbumCount: Int {
        Set(downloadedTracks.map { $0.albumId }).count
    }

    // MARK: - Helper Methods

    /// Get download progress for a specific album (0.0 to 1.0)
    func getAlbumDownloadProgress(trackIds: [String]) -> Double {
        guard !trackIds.isEmpty else { return 0.0 }

        var totalProgress = 0.0
        for trackId in trackIds {
            if let state = downloadStates[trackId] {
                switch state {
                case .downloaded:
                    totalProgress += 1.0
                case .downloading(let progress):
                    totalProgress += progress
                case .notDownloaded, .failed:
                    totalProgress += 0.0
                }
            }
        }

        return totalProgress / Double(trackIds.count)
    }

    /// Check if an album is fully downloaded
    func isAlbumDownloaded(trackIds: [String]) -> Bool {
        guard !trackIds.isEmpty else { return false }
        return trackIds.allSatisfy { isDownloaded(trackId: $0) }
    }

    /// Check if an album is currently downloading
    func isAlbumDownloading(trackIds: [String]) -> Bool {
        return trackIds.contains { trackId in
            if case .downloading = downloadStates[trackId] {
                return true
            }
            return false
        }
    }

    // MARK: - Private Properties
    private let fileManager = FileManager.default
    private let store: DownloadStore
    private let defaults: UserDefaults
    private var downloadTasks: [String: URLSessionDownloadTask] = [:] // trackId -> task
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "de.beutner.Aurelia.downloads")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private let jellyfinService = JellyfinService.shared

    /// Metadata for everything that has been asked for but has not produced a
    /// file yet — queued, in flight, or parked after a failure.
    private var pending: [String: PendingDownload] = [:]
    /// Track IDs waiting for a slot, oldest first.
    private var waiting: [String] = []
    /// Track IDs handed to URLSession right now.
    private var inFlight: Set<String> = []
    /// Retry timers, so a cancelled download does not come back to life.
    private var retryWorkItems: [String: DispatchWorkItem] = [:]

    // Track which albums are being downloaded to send completion notifications
    private var downloadingAlbums: [String: Set<String>] = [:] // albumId -> Set of trackIds

    /// The extension each in-flight download should be saved under, readable
    /// from the session's delegate queue. The delegate has to name the file
    /// before it can return, and `pending` is main-thread state.
    private let metadataLock = NSLock()
    private var expectedExtensions: [String: String] = [:]

    /// Progress arrives per chunk per task. Publishing each one would invalidate
    /// every download row in the UI thousands of times a second, so updates are
    /// buffered here and flushed on a timer.
    private let progressLock = NSLock()
    private var bufferedProgress: [String: Double] = [:]
    private var progressFlushScheduled = false
    private let progressFlushInterval: TimeInterval = 0.2

    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Initialization

    private var hasRequestedNotificationAuthorization: Bool

    init(store: DownloadStore = .shared, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        self.hasRequestedNotificationAuthorization = defaults.bool(
            forKey: Self.notificationRequestDefaultsKey
        )
        super.init()
        loadDownloadedTracks()
        restoreInFlightTasks()
    }

    /// Starts listening for the signals that unblock a held queue. Called once
    /// at launch, after `NetworkMonitor` is running.
    func start() {
        NetworkMonitor.shared.$isExpensive
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.pumpQueue()
            }
            .store(in: &cancellables)
    }

    // MARK: - Download Directory

    /// Returns the downloads directory, creating it if needed
    private var downloadsDirectory: URL {
        let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let downloadsPath = documentsPath.appendingPathComponent("Downloads", isDirectory: true)

        // Create directory if it doesn't exist
        if !fileManager.fileExists(atPath: downloadsPath.path) {
            try? fileManager.createDirectory(at: downloadsPath, withIntermediateDirectories: true)
        }

        return downloadsPath
    }

    /// Returns the artwork cache directory, creating it if needed
    private var artworkCacheDirectory: URL {
        let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let artworkPath = documentsPath.appendingPathComponent("AlbumArtwork", isDirectory: true)

        // Create directory if it doesn't exist
        if !fileManager.fileExists(atPath: artworkPath.path) {
            try? fileManager.createDirectory(at: artworkPath, withIntermediateDirectories: true)
        }

        return artworkPath
    }

    // MARK: - Download Operations

    /// Download a single track
    func downloadTrack(_ track: Track, origin: DownloadOrigin = .manual) {
        enqueue([track], origin: origin)
    }

    /// Download all tracks in an album
    func downloadAlbum(tracks: [Track]) {
        logger.info("Starting album download: \(tracks.count) tracks")

        // Download artwork for the album (use first track's artwork)
        if let firstTrack = tracks.first, let albumId = firstTrack.albumId {
            // Track this album download for completion notification
            let trackIds = Set(tracks.map { $0.id })
            downloadingAlbums[albumId] = trackIds

            Task {
                await cacheArtwork(for: albumId, from: firstTrack.artworkURL)
            }
        }

        enqueue(tracks, origin: .manual)
    }

    /// Adds tracks to the download queue on behalf of `origin`.
    ///
    /// Safe to call repeatedly with the same tracks: anything already
    /// downloaded, queued, or in flight only picks up the new owner.
    func enqueue(_ tracks: [Track], origin: DownloadOrigin) {
        guard !tracks.isEmpty else { return }

        requestNotificationAuthorizationIfNeeded()

        // A rule-driven batch spans many albums, and each one needs its cover
        // for the Downloads screen to have anything to show offline.
        if origin == .favoritesRule {
            var seenAlbums: Set<String> = []
            let artwork: [(String, String?)] = tracks.compactMap { track in
                guard let albumId = track.albumId, seenAlbums.insert(albumId).inserted else { return nil }
                return (albumId, track.artworkURL)
            }
            Task { [weak self] in
                for (albumId, url) in artwork {
                    await self?.cacheArtwork(for: albumId, from: url)
                }
            }
        }

        var added = false
        for track in tracks {
            guard track.albumId != nil else {
                logger.error("Cannot download track without albumId: \(track.name)")
                continue
            }

            if let index = downloadedTracks.firstIndex(where: { $0.trackId == track.id }) {
                // Already on disk. Record the new claim and move on.
                if downloadedTracks[index].owners.insert(origin).inserted {
                    store.upsert(downloadedTracks[index])
                }
                continue
            }

            if var existing = pending[track.id] {
                var changed = existing.owners.insert(origin).inserted

                // A parked failure that someone asks for again is worth another
                // try — the request says the situation changed.
                if failedDownloads.removeValue(forKey: track.id) != nil {
                    existing.attempts = 0
                    changed = true
                    appendToQueue(track.id, priority: origin == .manual)
                    added = true
                }

                if changed {
                    pending[track.id] = existing
                    store.upsertPending(existing)
                }
                continue
            }

            let record = PendingDownload(track: track, owners: [origin], quality: currentQuality)
            pending[track.id] = record
            store.upsertPending(record)
            downloadStates[track.id] = .downloading(progress: 0)
            appendToQueue(track.id, priority: origin == .manual)
            added = true
        }

        if added {
            pumpQueue()
        }
    }

    /// Records that `origin` also wants a track that is already on disk.
    func adopt(trackID: String, by origin: DownloadOrigin) {
        if let index = downloadedTracks.firstIndex(where: { $0.trackId == trackID }) {
            guard downloadedTracks[index].owners.insert(origin).inserted else { return }
            store.upsert(downloadedTracks[index])
        } else if var record = pending[trackID] {
            guard record.owners.insert(origin).inserted else { return }
            pending[trackID] = record
            store.upsertPending(record)
        }
    }

    /// Drops `origin`'s claim on a track. The file goes only if nobody else
    /// still wants it.
    func relinquish(trackID: String, by origin: DownloadOrigin) {
        if let index = downloadedTracks.firstIndex(where: { $0.trackId == trackID }) {
            guard downloadedTracks[index].owners.contains(origin) else { return }
            downloadedTracks[index].owners.remove(origin)
            if downloadedTracks[index].owners.isEmpty {
                deleteDownload(trackId: trackID)
            } else {
                store.upsert(downloadedTracks[index])
            }
            return
        }

        guard var record = pending[trackID], record.owners.contains(origin) else { return }
        record.owners.remove(origin)
        if record.owners.isEmpty {
            cancelPending(trackID)
        } else {
            pending[trackID] = record
            store.upsertPending(record)
        }
    }

    /// Track IDs that `origin` has asked for and that have not produced a file
    /// yet — queued, in flight, or parked after a failure.
    func pendingTrackIDs(ownedBy origin: DownloadOrigin) -> [String] {
        pending.compactMap { $0.value.owners.contains(origin) ? $0.key : nil }
    }

    /// Called when the cellular preference changes, so a queue held back for a
    /// cheaper connection can start immediately instead of on the next event.
    func networkPolicyDidChange() {
        let allowsCellular = defaults.bool(forKey: FavoritesOfflineDefaults.allowsCellular)
        if allowsCellular, NetworkMonitor.shared.isExpensive {
            // A task created while cellular was off refuses the only interface
            // there is and would sit there indefinitely. Rebuild those under
            // the new policy rather than leaving the queue wedged.
            let stalled = inFlight.filter { pending[$0]?.owners.contains(.manual) == false }
            for trackID in stalled {
                downloadTasks.removeValue(forKey: trackID)?.cancel()
                inFlight.remove(trackID)
                appendToQueue(trackID, priority: false)
            }
            activeDownloads = inFlight.count
        }
        pumpQueue()
    }

    /// True when the favorites rule is the reason this file is here and the
    /// user has no business deleting it by hand — it would come straight back.
    func isManagedByRule(trackId: String) -> Bool {
        if let track = downloadedTracks.first(where: { $0.trackId == trackId }) {
            return track.owners.contains(.favoritesRule)
        }
        return pending[trackId]?.owners.contains(.favoritesRule) ?? false
    }

    /// Delete a downloaded track, regardless of who was holding it.
    func deleteDownload(trackId: String) {
        cancelPending(trackId)

        // Find downloaded track metadata
        guard let downloadedTrack = downloadedTracks.first(where: { $0.trackId == trackId }) else {
            downloadStates[trackId] = .notDownloaded
            return
        }

        // Delete file
        let fileURL = downloadsDirectory.appendingPathComponent(downloadedTrack.fileName)
        try? fileManager.removeItem(at: fileURL)

        // Remove from metadata
        downloadedTracks.removeAll { $0.trackId == trackId }
        downloadStates[trackId] = .notDownloaded
        totalStorageUsed = max(0, totalStorageUsed - downloadedTrack.fileSize)
        store.remove(trackID: trackId)

        logger.info("Deleted download: \(downloadedTrack.trackName)")
    }

    /// Delete all downloads
    func deleteAllDownloads() {
        logger.info("Deleting all downloads")

        // Cancel all active downloads
        for (_, task) in downloadTasks {
            task.cancel()
        }
        downloadTasks.removeAll()
        for (_, item) in retryWorkItems {
            item.cancel()
        }
        retryWorkItems.removeAll()

        pending.removeAll()
        waiting.removeAll()
        inFlight.removeAll()
        failedDownloads.removeAll()
        store.removeAllPending()

        // Get all unique album IDs for artwork cleanup
        let albumIds = Set(downloadedTracks.map { $0.albumId })

        // Delete all files
        for downloadedTrack in downloadedTracks {
            let fileURL = downloadsDirectory.appendingPathComponent(downloadedTrack.fileName)
            try? fileManager.removeItem(at: fileURL)
        }

        // Delete all cached artwork
        for albumId in albumIds {
            deleteCachedArtwork(for: albumId)
        }

        // Clear metadata
        downloadedTracks.removeAll()
        downloadStates.removeAll()
        store.removeAllDownloads()

        totalStorageUsed = 0
        activeDownloads = 0
        queuedDownloads = 0
        isWaitingForWiFi = false
    }

    /// Delete every downloaded track and cached artwork belonging to an album.
    func deleteDownloads(for album: DownloadedAlbum) {
        for track in album.tracks {
            deleteDownload(trackId: track.trackId)
        }
        deleteCachedArtwork(for: album.albumId)
    }

    /// Drops every queued and in-flight download owned only by `origin`.
    /// Files already on disk are left alone.
    func cancelDownloads(for origin: DownloadOrigin) {
        for (trackID, record) in pending where record.owners.contains(origin) {
            if record.owners.count == 1 {
                cancelPending(trackID)
            } else {
                var updated = record
                updated.owners.remove(origin)
                pending[trackID] = updated
                store.upsertPending(updated)
            }
        }
        pumpQueue()
    }

    // MARK: - Queue Control

    func pause() {
        guard !isPaused else { return }
        isPaused = true
        for trackID in inFlight {
            downloadTasks[trackID]?.suspend()
        }
        logger.info("Paused downloads: \(self.inFlight.count) in flight")
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        for trackID in inFlight {
            downloadTasks[trackID]?.resume()
        }
        pumpQueue()
    }

    /// Puts every parked failure back in the queue.
    func retryFailedDownloads() {
        let failures = failedDownloads.keys
        guard !failures.isEmpty else { return }

        for trackID in failures {
            guard var record = pending[trackID] else { continue }
            record.attempts = 0
            pending[trackID] = record
            store.upsertPending(record)
            appendToQueue(trackID, priority: false)
        }
        failedDownloads.removeAll()
        pumpQueue()
    }

    // MARK: - Queue

    private func appendToQueue(_ trackID: String, priority: Bool) {
        guard !inFlight.contains(trackID), !waiting.contains(trackID) else { return }
        if priority {
            waiting.insert(trackID, at: 0)
        } else {
            waiting.append(trackID)
        }
        queuedDownloads = waiting.count
    }

    /// Starts as many queued downloads as the concurrency limit allows.
    private func pumpQueue() {
        guard !isPaused else { return }

        var held = false
        while inFlight.count < maxConcurrentDownloads {
            guard let index = waiting.firstIndex(where: { trackID in
                guard let record = pending[trackID] else { return false }
                if canStart(record) { return true }
                held = true
                return false
            }) else {
                break
            }

            let trackID = waiting.remove(at: index)
            startTask(for: trackID)
        }

        queuedDownloads = waiting.count
        activeDownloads = inFlight.count
        isWaitingForWiFi = held && inFlight.isEmpty
    }

    /// A rule-driven download waits for a cheaper connection unless the user
    /// has said otherwise. A download the user asked for by hand goes now — it
    /// is one album, and they are standing there watching it.
    private func canStart(_ record: PendingDownload) -> Bool {
        guard !record.owners.contains(.manual) else { return true }
        guard NetworkMonitor.shared.isExpensive || NetworkMonitor.shared.isConstrained else { return true }
        return defaults.bool(forKey: FavoritesOfflineDefaults.allowsCellular)
    }

    private func startTask(for trackID: String) {
        guard let record = pending[trackID] else { return }

        guard let downloadURL = jellyfinService.getDownloadURL(for: trackID, quality: record.quality) else {
            logger.error("Failed to get download URL for track: \(record.track.name)")
            fail(trackID, message: "Could not get download URL", permanent: true)
            return
        }

        var request = URLRequest(url: downloadURL)
        // The background session is created once and its configuration cannot
        // change afterwards, so the network policy rides on the request.
        if !record.owners.contains(.manual) {
            let allowsCellular = defaults.bool(forKey: FavoritesOfflineDefaults.allowsCellular)
            request.allowsCellularAccess = allowsCellular
            request.allowsExpensiveNetworkAccess = allowsCellular
            request.allowsConstrainedNetworkAccess = false
        }

        logger.info("Starting download: \(record.track.name)")

        // A transcode is served as MP3 whatever the source was called, and the
        // server may still label the response with the original file's name.
        if let fileExtension = record.quality.fileExtension {
            metadataLock.lock()
            expectedExtensions[trackID] = fileExtension
            metadataLock.unlock()
        }

        let task = urlSession.downloadTask(with: request)
        task.taskDescription = trackID // Store track ID in task for later reference
        downloadTasks[trackID] = task
        inFlight.insert(trackID)
        downloadStates[trackID] = .downloading(progress: 0)
        activeDownloads = inFlight.count
        task.resume()
    }

    /// Removes a track from the queue entirely, cancelling any work in flight.
    private func cancelPending(_ trackID: String) {
        metadataLock.lock()
        expectedExtensions.removeValue(forKey: trackID)
        metadataLock.unlock()

        retryWorkItems.removeValue(forKey: trackID)?.cancel()
        if let task = downloadTasks.removeValue(forKey: trackID) {
            task.cancel()
        }
        inFlight.remove(trackID)
        waiting.removeAll { $0 == trackID }
        pending.removeValue(forKey: trackID)
        failedDownloads.removeValue(forKey: trackID)
        store.removePending(trackID: trackID)

        if downloadStates[trackID]?.isDownloaded != true {
            downloadStates[trackID] = .notDownloaded
        }

        activeDownloads = inFlight.count
        queuedDownloads = waiting.count
    }

    private func fail(_ trackID: String, message: String, permanent: Bool) {
        inFlight.remove(trackID)
        downloadTasks.removeValue(forKey: trackID)
        activeDownloads = inFlight.count

        guard var record = pending[trackID] else {
            downloadStates[trackID] = .failed(error: message)
            pumpQueue()
            return
        }

        record.attempts += 1
        pending[trackID] = record
        store.upsertPending(record)

        if permanent || record.attempts >= maxAttempts {
            downloadStates[trackID] = .failed(error: message)
            failedDownloads[trackID] = DownloadFailure(message: message, isPermanent: permanent)
            logger.error("Giving up on \(record.track.name) after \(record.attempts) attempts: \(message)")

            NotificationCenter.default.post(
                name: NSNotification.Name("TrackDownloadFailed"),
                object: nil,
                userInfo: ["trackId": trackID, "error": message]
            )
            pumpQueue()
            return
        }

        // Back off, then try again. A batch on a flaky connection produces a
        // steady trickle of these and retrying immediately just burns them.
        let delay = pow(2.0, Double(record.attempts)) * 5.0
        logger.info("Retrying \(record.track.name) in \(Int(delay))s (attempt \(record.attempts))")

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retryWorkItems.removeValue(forKey: trackID)
            guard self.pending[trackID] != nil else { return }
            self.appendToQueue(trackID, priority: false)
            self.pumpQueue()
        }
        retryWorkItems[trackID] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)

        pumpQueue()
    }

    // MARK: - Playback Support

    /// Get local file URL for a track if downloaded, nil otherwise
    func getLocalURL(for trackId: String) -> URL? {
        guard let downloadedTrack = downloadedTracks.first(where: { $0.trackId == trackId }) else {
            return nil
        }

        let fileURL = downloadsDirectory.appendingPathComponent(downloadedTrack.fileName)

        // Verify file still exists
        guard fileManager.fileExists(atPath: fileURL.path) else {
            logger.warning("Downloaded file missing for track: \(trackId)")
            // Clean up metadata
            downloadedTracks.removeAll { $0.trackId == trackId }
            downloadStates[trackId] = .notDownloaded
            totalStorageUsed = max(0, totalStorageUsed - downloadedTrack.fileSize)
            store.remove(trackID: trackId)
            return nil
        }

        return fileURL
    }

    /// Check if a track is downloaded
    func isDownloaded(trackId: String) -> Bool {
        return downloadStates[trackId]?.isDownloaded ?? false
    }

    // MARK: - Metadata Persistence

    private func loadDownloadedTracks() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-downloads") {
            let fixture = DownloadedTrack(
                trackId: "ui-download-track",
                fileName: "ui-download-track.m4a",
                fileSize: 12_345_678,
                downloadDate: Date(timeIntervalSince1970: 0),
                trackName: "Downloaded Test Track",
                artistName: "Downloaded Test Artist",
                albumName: "Downloaded Test Album",
                duration: 245,
                albumId: "ui-download-album",
                trackNumber: 1,
                discNumber: 1,
                artistId: "ui-download-artist",
                productionYear: 2026,
                artworkURL: nil
            )
            downloadedTracks = [fixture]
            downloadStates[fixture.trackId] = .downloaded
            totalStorageUsed = fixture.fileSize
            return
        }
        #endif

        downloadedTracks = store.loadDownloads()
        for track in downloadedTracks {
            downloadStates[track.trackId] = .downloaded
        }
        totalStorageUsed = downloadedTracks.reduce(0) { $0 + $1.fileSize }

        for record in store.loadPending() {
            pending[record.track.id] = record
            downloadStates[record.track.id] = .downloading(progress: 0)
        }

        logger.info("Loaded \(self.downloadedTracks.count) downloads, \(self.pending.count) pending")
    }

    /// Reattaches to whatever the background session was still doing while the
    /// app was not running, then starts anything left over.
    ///
    /// Without this a relaunch would re-request tracks that are already
    /// downloading, and the duplicates would fight over the same destination.
    private func restoreInFlightTasks() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-downloads") { return }
        #endif
        guard !pending.isEmpty else { return }

        urlSession.getAllTasks { [weak self] tasks in
            DispatchQueue.main.async {
                guard let self else { return }
                for task in tasks {
                    guard let downloadTask = task as? URLSessionDownloadTask,
                          let trackID = task.taskDescription,
                          self.pending[trackID] != nil else {
                        continue
                    }
                    self.downloadTasks[trackID] = downloadTask
                    self.inFlight.insert(trackID)
                }

                for trackID in self.pending.keys where !self.inFlight.contains(trackID) {
                    self.appendToQueue(trackID, priority: false)
                }

                self.activeDownloads = self.inFlight.count
                self.logger.info("Reattached to \(self.inFlight.count) background downloads")
                self.pumpQueue()
            }
        }
    }

    // MARK: - Helper

    func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// Key for the download quality preference. Read rather than cached so a
    /// change applies to the next download without any plumbing.
    static let qualityDefaultsKey = "downloadQuality"

    /// Survives launches so the request is made exactly once per install.
    private static let notificationRequestDefaultsKey = "hasRequestedDownloadNotifications"

    /// The quality new downloads are fetched at.
    var currentQuality: DownloadQuality {
        DownloadQuality(rawValue: defaults.string(forKey: Self.qualityDefaultsKey) ?? "") ?? .original
    }

    /// Bytes of file per second of audio at a given quality.
    ///
    /// A transcode is arithmetic — the bitrate was dictated, so the size is
    /// known. The original is not: Jellyfin's item metadata carries a duration
    /// but no file size, so the only honest way to predict it is to measure
    /// what this library's own originals have cost.
    func bytesPerSecond(for quality: DownloadQuality) -> Double {
        if let known = quality.bytesPerSecond { return known }

        // Only originals may be sampled. Averaging a FLAC library together with
        // a batch of 128 kbps transcodes would describe neither.
        let samples = downloadedTracks.filter { $0.quality == .original && ($0.duration ?? 0) > 0 }
        let seconds = samples.reduce(0.0) { $0 + ($1.duration ?? 0) }
        guard seconds > 0 else { return 110_000 } // ~880 kbps, a middling FLAC
        return samples.reduce(0.0) { $0 + Double($1.fileSize) } / seconds
    }

    /// Bytes per second at whatever quality downloads are being taken now.
    var observedBytesPerSecond: Double {
        bytesPerSecond(for: currentQuality)
    }

    // MARK: - Artwork Caching

    /// Download and cache album artwork
    func cacheArtwork(for albumId: String, from urlString: String?) async {
        guard let urlString = urlString, let url = URL(string: urlString) else {
            logger.warning("No artwork URL provided for album: \(albumId)")
            return
        }

        let artworkFileName = "\(albumId).jpg"
        let artworkPath = artworkCacheDirectory.appendingPathComponent(artworkFileName)

        // Skip if already cached
        if fileManager.fileExists(atPath: artworkPath.path) {
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)

            // Verify it's valid image data
            guard let _ = UIImage(data: data) else {
                logger.error("Invalid image data for album: \(albumId)")
                return
            }

            try data.write(to: artworkPath)
        } catch {
            logger.error("Failed to cache artwork for album \(albumId): \(error.localizedDescription)")
        }
    }

    /// Get cached artwork URL for an album
    func getCachedArtworkURL(for albumId: String) -> URL? {
        let artworkFileName = "\(albumId).jpg"
        let artworkPath = artworkCacheDirectory.appendingPathComponent(artworkFileName)

        guard fileManager.fileExists(atPath: artworkPath.path) else {
            return nil
        }

        return artworkPath
    }

    /// Delete cached artwork for an album
    func deleteCachedArtwork(for albumId: String) {
        let artworkFileName = "\(albumId).jpg"
        let artworkPath = artworkCacheDirectory.appendingPathComponent(artworkFileName)

        try? fileManager.removeItem(at: artworkPath)
    }

    // MARK: - Album Completion Tracking

    /// Check if an album download is complete and send notification
    private func checkAlbumCompletion(trackId: String, albumId: String) {
        guard var pendingTracks = downloadingAlbums[albumId] else {
            return // Not tracking this album
        }

        // Remove this track from pending
        pendingTracks.remove(trackId)

        if pendingTracks.isEmpty {
            // Album complete!
            downloadingAlbums.removeValue(forKey: albumId)

            // Get album info from downloaded tracks
            if let albumTracks = downloadedTracks.filter({ $0.albumId == albumId }).first {
                // Haptic feedback for completion
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.success)

                sendAlbumCompleteNotification(
                    albumName: albumTracks.albumName,
                    artistName: albumTracks.artistName,
                    trackCount: downloadedTracks.filter({ $0.albumId == albumId }).count
                )
            }
        } else {
            // Update remaining tracks
            downloadingAlbums[albumId] = pendingTracks
        }
    }

    /// Asks for notifications the first time something is downloaded.
    ///
    /// Nothing in the app notifies about anything except a download finishing,
    /// so this is the first moment the permission means anything — and the
    /// request is provisional, which shows no prompt at all. Completions arrive
    /// quietly in Notification Center, and iOS asks the listener whether to
    /// keep them once they have seen a few. The right volume for "your album
    /// is ready", and it never interrupts anyone to ask.
    private func requestNotificationAuthorizationIfNeeded() {
        guard !hasRequestedNotificationAuthorization else { return }
        hasRequestedNotificationAuthorization = true
        defaults.set(true, forKey: Self.notificationRequestDefaultsKey)

        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .provisional]) { [weak self] granted, error in
                if let error {
                    self?.logger.error("Notification authorization failed: \(error.localizedDescription)")
                } else {
                    self?.logger.info("Notification authorization granted: \(granted)")
                }
            }
    }

    /// Send local notification for album download completion
    private func sendAlbumCompleteNotification(albumName: String, artistName: String, trackCount: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Download Complete"
        content.body = "\(albumName) by \(artistName) (\(trackCount) tracks)"
        content.sound = .default
        content.categoryIdentifier = "DOWNLOAD_COMPLETE"

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                self.logger.error("Failed to send notification: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Completion

    /// Main-thread half of a finished download: the file is already in place,
    /// this records it.
    private func finalize(trackID: String, fileName: String, fileSize: Int64) {
        guard let record = pending[trackID] else {
            // Nothing claims these bytes any more — the download was cancelled
            // or deleted while it was in flight.
            logger.warning("Discarding unclaimed download: \(trackID)")
            try? fileManager.removeItem(at: downloadsDirectory.appendingPathComponent(fileName))
            inFlight.remove(trackID)
            downloadTasks.removeValue(forKey: trackID)
            activeDownloads = inFlight.count
            pumpQueue()
            return
        }

        let track = record.track
        guard let albumId = track.albumId else {
            logger.error("Cannot store download without albumId: \(track.name)")
            cancelPending(trackID)
            pumpQueue()
            return
        }

        let downloadedTrack = DownloadedTrack(
            trackId: trackID,
            fileName: fileName,
            fileSize: fileSize,
            downloadDate: Date(),
            trackName: track.name,
            artistName: track.artistName,
            albumName: track.albumName,
            duration: track.duration,
            albumId: albumId,
            trackNumber: track.indexNumber,
            discNumber: track.parentIndexNumber,
            artistId: track.artistId,
            productionYear: track.productionYear,
            artworkURL: track.artworkURL,
            owners: record.owners,
            quality: record.quality
        )

        pending.removeValue(forKey: trackID)
        store.removePending(trackID: trackID)
        retryWorkItems.removeValue(forKey: trackID)?.cancel()
        failedDownloads.removeValue(forKey: trackID)
        inFlight.remove(trackID)
        downloadTasks.removeValue(forKey: trackID)

        if let index = downloadedTracks.firstIndex(where: { $0.trackId == trackID }) {
            totalStorageUsed -= downloadedTracks[index].fileSize
            downloadedTracks[index] = downloadedTrack
        } else {
            downloadedTracks.append(downloadedTrack)
        }
        totalStorageUsed += fileSize
        downloadStates[trackID] = .downloaded
        activeDownloads = inFlight.count
        store.upsert(downloadedTrack)

        NotificationCenter.default.post(
            name: NSNotification.Name("TrackDownloadCompleted"),
            object: nil,
            userInfo: ["trackName": downloadedTrack.trackName, "albumName": downloadedTrack.albumName]
        )

        // Only hand-picked album downloads announce themselves. A favorites
        // sync touches hundreds of albums and would bury the user in alerts;
        // it posts a single summary of its own when the whole set lands.
        checkAlbumCompletion(trackId: trackID, albumId: albumId)

        pumpQueue()
    }

    // MARK: - Progress buffering

    private func bufferProgress(_ progress: Double, for trackID: String) {
        progressLock.lock()
        bufferedProgress[trackID] = progress
        let needsFlush = !progressFlushScheduled
        if needsFlush {
            progressFlushScheduled = true
        }
        progressLock.unlock()

        guard needsFlush else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + progressFlushInterval) { [weak self] in
            self?.flushProgress()
        }
    }

    private func flushProgress() {
        progressLock.lock()
        let batch = bufferedProgress
        bufferedProgress.removeAll(keepingCapacity: true)
        progressFlushScheduled = false
        progressLock.unlock()

        guard !batch.isEmpty else { return }
        for (trackID, progress) in batch where downloadStates[trackID]?.isDownloaded != true {
            downloadStates[trackID] = .downloading(progress: progress)
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadManager: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let trackId = downloadTask.taskDescription else {
            logger.error("Download task missing track ID")
            return
        }

        // The temporary file is gone the moment this method returns, so the
        // move has to happen here rather than on the main thread. It touches
        // no shared state, only the filesystem.
        metadataLock.lock()
        let requestedExtension = expectedExtensions.removeValue(forKey: trackId)
        metadataLock.unlock()

        let fileExtension = requestedExtension
            ?? downloadTask.response?.suggestedFilename?.split(separator: ".").last.map(String.init)
            ?? "mp3"
        let fileName = "\(trackId).\(fileExtension)"
        let destinationURL = downloadsDirectory.appendingPathComponent(fileName)

        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: location, to: destinationURL)

            let attributes = try fileManager.attributesOfItem(atPath: destinationURL.path)
            let fileSize = attributes[.size] as? Int64 ?? 0

            DispatchQueue.main.async {
                self.finalize(trackID: trackId, fileName: fileName, fileSize: fileSize)
            }
        } catch {
            logger.error("Failed to save download: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.fail(trackId, message: error.localizedDescription, permanent: false)
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let trackId = downloadTask.taskDescription else { return }
        guard totalBytesExpectedToWrite > 0 else { return }

        bufferProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), for: trackId)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error, let trackId = task.taskDescription else { return }

        // A cancelled task was cancelled by us; its bookkeeping is already done.
        if (error as NSError).code == NSURLErrorCancelled { return }

        let message = error.localizedDescription
        DispatchQueue.main.async {
            guard self.downloadStates[trackId]?.isDownloaded != true else { return }
            self.fail(trackId, message: message, permanent: false)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            let handler = self.backgroundCompletionHandler
            self.backgroundCompletionHandler = nil
            handler?()
        }
    }
}
