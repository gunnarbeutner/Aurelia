import Foundation
import UIKit
import Combine
import os.log

enum LibrarySyncTrigger: Sendable {
    case launch, pullToRefresh, manual, rebuild, serverEvent
}

enum LibrarySyncStatus: Equatable, Sendable {
    case idle
    case syncing(message: String, progress: Double)
    case failed(message: String, hasCachedLibrary: Bool)
}

/// Synchronizes exclusively through AureliaSync's journal protocol. There is
/// intentionally no stock-Jellyfin catalog fallback: it could silently produce
/// a different consistency model and reintroduce the expensive startup crawl.
@MainActor
final class LibrarySyncCoordinator: ObservableObject {
    static let shared = LibrarySyncCoordinator(service: .shared, repository: .shared, client: .shared)

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Aurelia",
        category: "LibrarySync"
    )

    @Published private(set) var status: LibrarySyncStatus = .idle

    private let service: JellyfinService
    private let repository: LibraryRepository
    private let client: AureliaSyncClient
    private var activeTask: Task<Void, Error>?
    private var pollTask: Task<Void, Never>?
    private let pollInterval: Duration = .seconds(5 * 60)
    private let maximumIdleDuration: Duration = .seconds(10 * 60)

    init(service: JellyfinService, repository: LibraryRepository, client: AureliaSyncClient) {
        self.service = service
        self.repository = repository
        self.client = client
    }

    /// Prototype freshness path. Plugin-specific notifications will call sync
    /// with `.serverEvent`; this lightweight poll remains a safety net.
    func startEventMonitoring() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.pollInterval ?? .seconds(300))
                guard !Task.isCancelled, let self, self.service.isAuthenticated else { continue }
                try? await self.sync(trigger: .serverEvent)
                await LibraryStore.shared.reload()
            }
        }
    }

    func reconnectEventStream() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.sync(trigger: .serverEvent)
            await LibraryStore.shared.reload()
        }
    }

    func stopEventMonitoring() {
        pollTask?.cancel()
        pollTask = nil
    }

    func sync(trigger: LibrarySyncTrigger) async throws {
        if let activeTask { try await activeTask.value; return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let assertion = UIApplication.shared.beginBackgroundTask(withName: "AureliaSync")
            defer { if assertion != .invalid { UIApplication.shared.endBackgroundTask(assertion) } }
            try await self.performSync(trigger: trigger)
        }
        activeTask = task
        defer { activeTask = nil }
        try await task.value
    }

    private func performSync(trigger: LibrarySyncTrigger) async throws {
        guard let scope = service.libraryScope else { throw JellyfinError.notAuthenticated }
        let syncStartedAt = ContinuousClock.now
        do {
            status = .syncing(message: "Contacting Aurelia Sync…", progress: 0.02)
            let pluginStatus = try await client.status()
            guard pluginStatus.enabled else { throw AureliaSyncError.disabled(pluginStatus.healthDetail) }
            guard pluginStatus.healthy else { throw AureliaSyncError.disabled(pluginStatus.healthDetail ?? "Aurelia Sync is unhealthy.") }
            guard pluginStatus.isCompatible else {
                throw AureliaSyncError.incompatible("no common protocol or schema version")
            }

            var local = try await repository.aureliaSyncState(in: scope)
            let forceSnapshot = trigger == .rebuild
            if forceSnapshot { try await repository.resetAureliaSyncStaging(in: scope); local = nil }

            // A commit is durable locally before it is acknowledged remotely.
            // Retry that exact session/commit first. If the session expired,
            // opening from the last server checkpoint safely replays it.
            if let pending = local?.pendingAcknowledgement,
               let pendingSessionID = local?.pendingSessionID {
                status = .syncing(message: "Confirming saved changes…", progress: 0.04)
                do {
                    let token = try await client.acknowledge(pending, sessionID: pendingSessionID)
                    try await repository.markAureliaSyncAcknowledged(pending, checkpointToken: token, in: scope)
                    local = try await repository.aureliaSyncState(in: scope)
                } catch let error as AureliaSyncError {
                    switch error {
                    case .required, .http(410, _): break // Replay through a new session.
                    default: throw error
                    }
                }
            }

            // Checkpoints created by builds predating the publication marker
            // cannot prove that their generation reached the live catalog. Ask
            // the server for one fresh delivery while keeping the old UI data.
            let needsPublicationRecovery = local?.checkpointToken != nil
                && local?.publishedSnapshotGeneration == nil
            let session = try await client.openSession(
                checkpoint: needsPublicationRecovery ? nil : local?.checkpointToken,
                reset: forceSnapshot || needsPublicationRecovery
            )
            Self.logger.info(
                "Opened Aurelia Sync session in \(session.mode.rawValue, privacy: .public) mode; reason: \(session.reason ?? "none", privacy: .public)"
            )
            defer { Task { await self.client.close(sessionID: session.sessionId) } }

            if session.mode == .snapshot,
               let previousGeneration = local?.snapshotGeneration,
               let incomingGeneration = session.snapshotGeneration,
               previousGeneration != incomingGeneration {
                // A resumed staging area only belongs to the snapshot generation
                // that produced it. Never merge rows from two generations.
                try await repository.discardAureliaSyncSnapshotRows(in: scope)
            }

            var cursor = session.cursor
            var segments = 0
            let clock = ContinuousClock()
            var lastRecordAt = clock.now
            while true {
                try Task.checkCancellation()
                status = .syncing(
                    message: session.mode == .snapshot ? "Updating your library…" : "Applying library changes…",
                    progress: min(0.08 + Double(segments) * 0.03, 0.92)
                )
                let segment = try await client.stream(session: session, after: cursor)
                let acknowledgement = AureliaSyncAcknowledgement(
                    throughCursor: segment.cursor,
                    clientCommitId: UUID().uuidString.lowercased(),
                    recordCount: segment.records.count
                )
                let maximumSequence = segment.records.compactMap(\.sequence).max()
                let baseURL = service.baseURL
                let changes = try await Task.detached(priority: .utility) {
                    try Self.changes(from: segment.records, baseURL: baseURL)
                }.value

                // While materialization is running the server deliberately
                // sends empty, unfinished segments. There is no new local
                // state to commit or acknowledge; just ask again. Likewise, a
                // completed generation already published locally needs no
                // second promotion when its terminal segment is empty.
                if segment.records.isEmpty {
                    if segment.caughtUp,
                       local?.publishedSnapshotGeneration == session.snapshotGeneration {
                        break
                    }
                    if !segment.caughtUp {
                        if lastRecordAt.duration(to: clock.now) >= maximumIdleDuration {
                            throw AureliaSyncError.incompatible(
                                "the server made no library progress for ten minutes"
                            )
                        }
                        cursor = segment.cursor
                        segments += 1
                        continue
                    }
                }

                if session.mode == .snapshot {
                    if segment.caughtUp {
                        try await repository.promoteAureliaSyncSnapshot(
                            changes.catalog, session: session, acknowledgement: acknowledgement,
                            sequence: maximumSequence, in: scope
                        )
                    } else {
                        try await repository.appendAureliaSyncSnapshotSegment(
                            changes.catalog, session: session, acknowledgement: acknowledgement,
                            sequence: maximumSequence, in: scope
                        )
                    }
                } else {
                    _ = try await repository.applyDelta(
                        changes.delta, in: scope, aureliaSync: session,
                        acknowledgement: acknowledgement, sequence: maximumSequence
                    )
                }

                let token = try await client.acknowledge(acknowledgement, sessionID: session.sessionId)
                try await repository.markAureliaSyncAcknowledged(acknowledgement, checkpointToken: token, in: scope)
                cursor = segment.cursor
                segments += 1
                if segment.caughtUp { break }
                if !segment.records.isEmpty {
                    lastRecordAt = clock.now
                }
            }

            status = .idle
            let elapsed = syncStartedAt.duration(to: ContinuousClock.now)
            Self.logger.info(
                "Completed Aurelia Sync in \(session.mode.rawValue, privacy: .public) mode after \(segments, privacy: .public) segments in \(String(describing: elapsed), privacy: .public)"
            )
            NetworkMonitor.shared.noteServerReachable()
        } catch is CancellationError {
            status = .idle
            throw CancellationError()
        } catch {
            let hasCache = (try? await repository.librarySnapshot(in: scope, includeTracks: false).hasCachedLibrary) ?? false
            status = .failed(message: error.localizedDescription, hasCachedLibrary: hasCache)
            throw error
        }
    }

    nonisolated private struct Changes: Sendable {
        var catalog = LibraryCatalog(albums: [], artists: [], tracks: [], playlists: [], genres: [], playlistEntries: [])
        var delta: LibraryDelta
    }

    nonisolated private static func changes(from records: [AureliaSyncRecord], baseURL: String) throws -> Changes {
        var albums: [Album] = []; var artists: [Artist] = []; var tracks: [Track] = []
        var playlists: [Playlist] = []; var genres: [Genre] = []; var entries: [LibraryPlaylistEntry] = []
        var albumArtistIDs = Set<String>()
        var userData: [LibraryUserDataChange] = []; var removed = Set<String>(); var refreshed = Set<String>()
        for record in records {
            switch record.kind {
            case "item.upsert":
                guard let payload = record.payload else { throw AureliaSyncError.invalidPayload }
                switch record.entityType {
                case "track": tracks.append(try payload.track(fallbackID: record.entityId, baseURL: baseURL))
                case "album": albums.append(try payload.album(fallbackID: record.entityId, baseURL: baseURL))
                case "artist":
                    let artist = try payload.artist(fallbackID: record.entityId, baseURL: baseURL)
                    artists.append(artist)
                    if payload.isAlbumArtist == true { albumArtistIDs.insert(artist.id) }
                case "playlist":
                    let playlist = try payload.playlist(fallbackID: record.entityId, baseURL: baseURL)
                    playlists.append(playlist)
                    refreshed.insert(playlist.id)
                case "genre": genres.append(try payload.genre(fallbackID: record.entityId))
                default: throw AureliaSyncError.invalidPayload
                }
            case "item.delete":
                guard let id = record.entityId else { throw AureliaSyncError.invalidPayload }
                removed.insert(id)
            case "playlist.replace":
                guard let payload = record.payload, let playlistID = payload.playlistID,
                      let position = payload.position else { throw AureliaSyncError.invalidPayload }
                refreshed.insert(playlistID)
                entries.append(.init(playlistID: playlistID, track: try payload.track(fallbackID: record.entityId, baseURL: baseURL), position: position))
            case "userData.upsert":
                guard let payload = record.payload, let itemID = payload.id ?? record.entityId else { throw AureliaSyncError.invalidPayload }
                userData.append(.init(itemID: itemID, isFavorite: payload.isFavorite, lastPlayedAt: payload.lastPlayedAt, playCount: payload.playCount, playbackPositionTicks: payload.playbackPositionTicks))
            case "relationship.replace", "control.reconcile": break
            default: throw AureliaSyncError.invalidPayload
            }
        }
        let now = Date()
        let catalog = LibraryCatalog(albums: albums, artists: artists, tracks: tracks, playlists: playlists, genres: genres, playlistEntries: entries, userData: userData, albumArtistIDs: albumArtistIDs)
        let delta = LibraryDelta(albums: albums, artists: artists, tracks: tracks, playlists: playlists, genres: genres, userData: userData, refreshedPlaylistIDs: refreshed, playlistEntries: entries, removedItemIDs: removed, metadataWatermark: now, userDataWatermark: now)
        return Changes(catalog: catalog, delta: delta)
    }
}
