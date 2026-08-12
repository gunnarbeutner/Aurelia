import Foundation
import Combine
import UIKit

enum LibrarySyncTrigger: Sendable {
    case launch
    case pullToRefresh
    case manual
    case rebuild
    case serverEvent
}

enum LibrarySyncStatus: Equatable, Sendable {
    case idle
    case syncing(message: String, progress: Double)
    case failed(message: String, hasCachedLibrary: Bool)
}

/// Keeps SQLite current using Jellyfin's saved-at watermarks. A complete rebuild
/// is reserved for a missing cache or an explicit Settings action; ordinary
/// launches and pull-to-refreshes only fetch changed rows.
@MainActor
final class LibrarySyncCoordinator: ObservableObject {
    static let shared = LibrarySyncCoordinator(
        service: .shared,
        repository: .shared
    )

    @Published private(set) var status: LibrarySyncStatus = .idle

    private let service: JellyfinService
    private let repository: LibraryRepository
    private lazy var eventStream = JellyfinLibraryEventStream(service: service)
    private var activeTask: Task<Void, Error>?
    private var eventDebounceTask: Task<Void, Never>?
    private let pageSize = 500
    private let overlap: TimeInterval = 5 * 60
    private let reconciliationInterval: TimeInterval = 24 * 60 * 60
    /// How long a partially staged catalog stays resumable. Past this the server
    /// has likely drifted far enough that a fresh crawl is cheaper than
    /// reasoning about what changed underneath the staged rows.
    private static let stagingLifetime: TimeInterval = 24 * 60 * 60

    init(
        service: JellyfinService,
        repository: LibraryRepository
    ) {
        self.service = service
        self.repository = repository
    }

    func startEventMonitoring() {
        eventStream.start { [weak self] _ in
            self?.scheduleEventSync()
        }
    }

    func stopEventMonitoring() {
        eventDebounceTask?.cancel()
        eventDebounceTask = nil
        eventStream.stop()
    }

    private func scheduleEventSync() {
        eventDebounceTask?.cancel()
        eventDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            try? await self.sync(trigger: .serverEvent)
            await LibraryStore.shared.reload()
        }
    }

    func sync(trigger: LibrarySyncTrigger) async throws {
        if let activeTask {
            try await activeTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            // Without an assertion iOS suspends the app on the way to the
            // background, stranding the sync mid-page. This does not guarantee
            // completion, it just buys the current page time to land.
            let assertion = UIApplication.shared.beginBackgroundTask(
                withName: "LibrarySync"
            )
            defer {
                if assertion != .invalid {
                    UIApplication.shared.endBackgroundTask(assertion)
                }
            }
            try await self.performSync(trigger: trigger)
        }
        activeTask = task
        defer { activeTask = nil }
        try await task.value
    }

    private func performSync(trigger: LibrarySyncTrigger) async throws {
        guard let scope = service.libraryScope else {
            throw JellyfinError.notAuthenticated
        }

        do {
            let state = try await repository.syncState(in: scope)
            if state == nil || trigger == .rebuild {
                try await performFullSync(in: scope)
            } else if let state {
                try await performIncrementalSync(state: state, in: scope)
            }

            // Cross-client recency is a small, independently refreshed window.
            // A failure here must not invalidate the catalog commit.
            if let recentItems = try? await service.fetchRecentlyPlayedTracks(limit: 100) {
                status = .syncing(message: "Updating recent plays…", progress: 0.99)
                await repository.replaceRecentlyPlayed(
                    recentTrackEntries(from: recentItems, baseURL: service.baseURL),
                    in: scope
                )
            }
            status = .idle
        } catch is CancellationError {
            status = .idle
            throw CancellationError()
        } catch {
            let hasCache = (try? await repository.librarySnapshot(
                in: scope,
                includeTracks: false
            ).hasCachedLibrary) ?? false
            status = .failed(message: error.localizedDescription, hasCachedLibrary: hasCache)
            throw error
        }
    }

    /// Ordered stages of a full sync. The stage name is persisted alongside the
    /// page cursor, so an interrupted sync resumes at the page it died on rather
    /// than refetching the whole library.
    private enum FullSyncStage: String, CaseIterable {
        case albums, artists, tracks, playlists, genres, playlistEntries

        var progressRange: ClosedRange<Double> {
            switch self {
            case .albums: return 0.02...0.14
            case .artists: return 0.14...0.25
            case .tracks: return 0.25...0.67
            case .playlists: return 0.67...0.73
            case .genres: return 0.73...0.78
            case .playlistEntries: return 0.78...0.95
            }
        }
    }

    private func performFullSync(in scope: LibraryScope) async throws {
        // A staged sync is only resumable while the server still agrees with
        // what we already wrote. Anything older than a day is treated as stale
        // and discarded rather than merged into a fresh crawl.
        let existing = try await repository.stagingProgress(in: scope)
        let resumable = existing.flatMap { progress -> LibraryStagingProgress? in
            Date().timeIntervalSince(progress.startedAt) < Self.stagingLifetime ? progress : nil
        }
        if resumable == nil {
            // Either nothing was staged, or what was staged is too old to trust
            // against the current server state.
            try await repository.resetStagedLibrary(in: scope)
        }
        let syncStartedAt = resumable?.startedAt ?? Date()

        let resumeStage = resumable.flatMap { FullSyncStage(rawValue: $0.stage) }
        let baseURL = service.baseURL

        let resumeIndex = resumeStage.flatMap { FullSyncStage.allCases.firstIndex(of: $0) } ?? 0

        for (index, stage) in FullSyncStage.allCases.enumerated() {
            try Task.checkCancellation()
            // Stages complete in order, so anything before the recorded stage is
            // already durable in the staging scope.
            if index < resumeIndex { continue }
            let startOffset = (stage == resumeStage) ? (resumable?.nextOffset ?? 0) : 0

            switch stage {
            case .albums:
                try await streamStage(stage, from: startOffset, in: scope, startedAt: syncStartedAt) { limit, offset in
                    try await self.service.fetchMusicItemsPage(
                        includeItemTypes: "MusicAlbum",
                        limit: limit,
                        startIndex: offset
                    )
                } chunk: { items in
                    LibraryCatalog(
                        albums: items.map { Album(from: $0, baseURL: baseURL) },
                        artists: [], tracks: [], playlists: [], genres: [],
                        playlistEntries: [],
                        userData: Self.userDataChanges(from: items)
                    )
                }

            case .artists:
                try await streamStage(stage, from: startOffset, in: scope, startedAt: syncStartedAt) { limit, offset in
                    try await self.service.fetchArtistsPage(limit: limit, startIndex: offset)
                } chunk: { items in
                    LibraryCatalog(
                        albums: [],
                        artists: items.map { Artist(from: $0, baseURL: baseURL) },
                        tracks: [], playlists: [], genres: [],
                        playlistEntries: [],
                        userData: Self.userDataChanges(from: items)
                    )
                }

            case .tracks:
                try await streamStage(stage, from: startOffset, in: scope, startedAt: syncStartedAt) { limit, offset in
                    try await self.service.fetchMusicItemsPage(
                        includeItemTypes: "Audio",
                        limit: limit,
                        startIndex: offset
                    )
                } chunk: { items in
                    LibraryCatalog(
                        albums: [], artists: [],
                        tracks: items.map { Track(from: $0, baseURL: baseURL) },
                        playlists: [], genres: [],
                        playlistEntries: [],
                        userData: Self.userDataChanges(from: items)
                    )
                }

            case .playlists:
                try await streamStage(stage, from: startOffset, in: scope, startedAt: syncStartedAt) { limit, offset in
                    try await self.service.fetchPlaylistsPage(limit: limit, startIndex: offset)
                } chunk: { items in
                    LibraryCatalog(
                        albums: [], artists: [], tracks: [],
                        playlists: items.map { Playlist(from: $0, baseURL: baseURL) },
                        genres: [],
                        playlistEntries: [],
                        userData: Self.userDataChanges(from: items)
                    )
                }

            case .genres:
                try await streamStage(stage, from: startOffset, in: scope, startedAt: syncStartedAt) { limit, offset in
                    try await self.service.fetchGenresPage(limit: limit, startIndex: offset)
                } chunk: { items in
                    LibraryCatalog(
                        albums: [], artists: [], tracks: [], playlists: [],
                        genres: items.map(Genre.init(from:)),
                        playlistEntries: [],
                        userData: []
                    )
                }

            case .playlistEntries:
                try await stagePlaylistEntries(
                    resumeDetail: stage == resumeStage ? resumable?.detail : nil,
                    resumeOffset: startOffset,
                    startedAt: syncStartedAt,
                    baseURL: baseURL,
                    in: scope
                )
            }
        }

        try Task.checkCancellation()
        status = .syncing(message: "Updating local library…", progress: 0.96)
        try await repository.promoteStagedLibrary(in: scope, syncedAt: syncStartedAt)

        if let snapshot = try? await repository.librarySnapshot(
            in: scope,
            includeTracks: true
        ) {
            PhoneConnectivityManager.shared.syncLibrarySnapshotToWatch(
                snapshot: snapshot,
                scope: scope
            )
        }
    }

    /// Pages one stage straight into the staging scope. Each page is persisted
    /// with its cursor in a single transaction before the next is requested, so
    /// termination costs at most one page of work.
    private func streamStage(
        _ stage: FullSyncStage,
        from startOffset: Int,
        detail: String? = nil,
        in scope: LibraryScope,
        startedAt: Date,
        fetch: @escaping (_ limit: Int, _ offset: Int) async throws -> ItemsResponse,
        chunk: ([BaseItemDto]) -> LibraryCatalog
    ) async throws {
        var offset = startOffset
        var expectedTotal = 0

        while true {
            try Task.checkCancellation()
            updateProgress(
                label: stage.rawValue,
                completed: min(offset, expectedTotal),
                total: expectedTotal,
                fraction: expectedTotal > 0 ? min(Double(offset) / Double(expectedTotal), 1) : 0,
                range: stage.progressRange
            )

            let page = try await fetchPageWithRetry {
                try await fetch(self.pageSize, offset)
            }
            expectedTotal = max(expectedTotal, page.TotalRecordCount)
            if page.Items.isEmpty { break }

            offset += page.Items.count
            try await repository.appendStagedChunk(
                chunk(page.Items),
                stage: stage.rawValue,
                nextOffset: offset,
                detail: detail,
                startedAt: startedAt,
                in: scope
            )

            if page.Items.count < pageSize || offset >= expectedTotal { break }
        }

        // Record the stage as finished even when it yielded nothing, so a
        // resume does not repeat it.
        try await repository.appendStagedChunk(
            LibraryCatalog(
                albums: [], artists: [], tracks: [], playlists: [], genres: [],
                playlistEntries: [], userData: []
            ),
            stage: stage.rawValue,
            nextOffset: offset,
            detail: detail,
            startedAt: startedAt,
            in: scope
        )
    }

    /// Playlist contents are a nested crawl, so the cursor also records which
    /// playlist is in flight. Playlists are walked in the same deterministic
    /// order the repository returns them.
    private func stagePlaylistEntries(
        resumeDetail: String?,
        resumeOffset: Int,
        startedAt: Date,
        baseURL: String,
        in scope: LibraryScope
    ) async throws {
        let playlistIDs = try await repository.stagedPlaylistIDs(in: scope)
        guard !playlistIDs.isEmpty else { return }

        var startIndex = 0
        if let resumeDetail, let index = playlistIDs.firstIndex(of: resumeDetail) {
            startIndex = index
        }

        for index in startIndex..<playlistIDs.count {
            try Task.checkCancellation()
            let playlistID = playlistIDs[index]
            let count = max(playlistIDs.count, 1)
            let lower = 0.78 + 0.17 * Double(index) / Double(count)
            let upper = 0.78 + 0.17 * Double(index + 1) / Double(count)
            var offset = (playlistID == resumeDetail) ? resumeOffset : 0
            var expectedTotal = 0
            var position = offset

            while true {
                try Task.checkCancellation()
                updateProgress(
                    label: "playlist \(index + 1) of \(playlistIDs.count)",
                    completed: min(offset, expectedTotal),
                    total: expectedTotal,
                    fraction: expectedTotal > 0 ? min(Double(offset) / Double(expectedTotal), 1) : 0,
                    range: lower...upper
                )

                let page = try await fetchPageWithRetry {
                    try await self.service.fetchTracksPage(
                        parentId: playlistID,
                        limit: self.pageSize,
                        startIndex: offset
                    )
                }
                expectedTotal = max(expectedTotal, page.TotalRecordCount)
                if page.Items.isEmpty { break }

                let entries = page.Items.map { item -> LibraryPlaylistEntry in
                    let entry = LibraryPlaylistEntry(
                        playlistID: playlistID,
                        track: Track(from: item, baseURL: baseURL),
                        position: position
                    )
                    position += 1
                    return entry
                }
                offset += page.Items.count

                try await repository.appendStagedChunk(
                    LibraryCatalog(
                        albums: [], artists: [], tracks: [], playlists: [], genres: [],
                        playlistEntries: entries,
                        userData: []
                    ),
                    stage: FullSyncStage.playlistEntries.rawValue,
                    nextOffset: offset,
                    detail: playlistID,
                    startedAt: startedAt,
                    in: scope
                )

                if page.Items.count < pageSize || offset >= expectedTotal { break }
            }
        }
    }

    private func performIncrementalSync(
        state: LibrarySyncState,
        in scope: LibraryScope
    ) async throws {
        let syncStartedAt = Date()
        let metadataSince = state.metadataWatermark.addingTimeInterval(-overlap)
        let userSince = state.userDataWatermark.addingTimeInterval(-overlap)
        let reconcile = state.lastReconciledAt.map {
            syncStartedAt.timeIntervalSince($0) >= reconciliationInterval
        } ?? true

        let metadataItems = try await allPages(
            label: "recent library changes",
            progressRange: 0.03...0.32
        ) { limit, offset in
            try await self.service.fetchMusicItemsPage(
                includeItemTypes: "Audio,MusicAlbum,Playlist",
                limit: limit,
                startIndex: offset,
                minDateLastSaved: metadataSince
            )
        }
        try Task.checkCancellation()
        let userItems = try await allPages(
            label: "favorites and play state",
            progressRange: 0.32...0.55
        ) { limit, offset in
            try await self.service.fetchMusicItemsPage(
                includeItemTypes: "Audio,MusicAlbum,Playlist,MusicArtist",
                limit: limit,
                startIndex: offset,
                minDateLastSavedForUser: userSince
            )
        }

        let baseURL = service.baseURL
        var albums = metadataItems.filter { $0.Type == .MusicAlbum }
            .map { Album(from: $0, baseURL: baseURL) }
        var tracks = metadataItems.filter { $0.Type == .Audio }
            .map { Track(from: $0, baseURL: baseURL) }
        var playlists = metadataItems.filter { $0.Type == .Playlist }
            .map { Playlist(from: $0, baseURL: baseURL) }
        let artists = userItems.filter { $0.Type == .MusicArtist }
            .map { Artist(from: $0, baseURL: baseURL) }
        albums.append(contentsOf: userItems.filter { $0.Type == .MusicAlbum }
            .map { Album(from: $0, baseURL: baseURL) })
        tracks.append(contentsOf: userItems.filter { $0.Type == .Audio }
            .map { Track(from: $0, baseURL: baseURL) })
        playlists.append(contentsOf: userItems.filter { $0.Type == .Playlist }
            .map { Playlist(from: $0, baseURL: baseURL) })
        var removedIDs = Set<String>()
        var replacementArtists: [Artist]?
        var replacementGenres: [Genre]?
        var playlistItemsToRefresh = metadataItems.filter { $0.Type == .Playlist }

        if reconcile {
            status = .syncing(message: "Checking the library inventory…", progress: 0.57)
            let inventory = try await allPages(
                label: "library inventory",
                progressRange: 0.57...0.72
            ) { limit, offset in
                try await self.service.fetchMusicItemsPage(
                    includeItemTypes: "Audio,MusicAlbum,Playlist",
                    limit: limit,
                    startIndex: offset,
                    enableUserData: false,
                    enableImages: false,
                    fields: "BasicSyncInfo"
                )
            }
            let serverIDs = Set(inventory.map(\.Id))
            let localIDs = try await repository.primaryCatalogItemIDs(in: scope)
            removedIDs = localIDs.subtracting(serverIDs)

            // An inventory also repairs old/partial caches by fetching rows
            // known to Jellyfin but absent locally.
            let missingIDs = serverIDs.subtracting(localIDs)
            if !missingIDs.isEmpty {
                status = .syncing(
                    message: "Repairing \(missingIDs.count) missing items…",
                    progress: 0.73
                )
                let missing = try await service.fetchMusicItems(ids: Array(missingIDs))
                albums.append(contentsOf: missing.filter { $0.Type == .MusicAlbum }
                    .map { Album(from: $0, baseURL: baseURL) })
                tracks.append(contentsOf: missing.filter { $0.Type == .Audio }
                    .map { Track(from: $0, baseURL: baseURL) })
                playlists.append(contentsOf: missing.filter { $0.Type == .Playlist }
                    .map { Playlist(from: $0, baseURL: baseURL) })
            }

            let artistItems = try await allPages(
                label: "artists",
                progressRange: 0.73...0.79
            ) { limit, offset in
                try await self.service.fetchArtistsPage(limit: limit, startIndex: offset)
            }
            replacementArtists = artistItems.map { Artist(from: $0, baseURL: baseURL) }

            let genreItems = try await allPages(
                label: "genres",
                progressRange: 0.79...0.84
            ) { limit, offset in
                try await self.service.fetchGenresPage(limit: limit, startIndex: offset)
            }
            replacementGenres = genreItems.map(Genre.init(from:))

            // Daily reconciliation refreshes every playlist membership so
            // removals and reorderings are reflected even when the playlist
            // item's own saved timestamp did not change.
            playlistItemsToRefresh = inventory.filter { $0.Type == .Playlist }
            if !playlistItemsToRefresh.isEmpty {
                let detailed = try await service.fetchMusicItems(
                    ids: playlistItemsToRefresh.map(\.Id)
                )
                playlistItemsToRefresh = detailed.filter { $0.Type == .Playlist }
            }
        }

        playlistItemsToRefresh = Array(
            Dictionary(uniqueKeysWithValues: playlistItemsToRefresh.map { ($0.Id, $0) }).values
        )
        var playlistEntries: [LibraryPlaylistEntry] = []
        for (index, playlist) in playlistItemsToRefresh.enumerated() {
            let count = max(playlistItemsToRefresh.count, 1)
            let lower = 0.84 + 0.11 * Double(index) / Double(count)
            let upper = 0.84 + 0.11 * Double(index + 1) / Double(count)
            let entries = try await allPages(
                label: "playlist \(index + 1) of \(playlistItemsToRefresh.count)",
                progressRange: lower...upper
            ) { limit, offset in
                try await self.service.fetchTracksPage(
                    parentId: playlist.Id,
                    limit: limit,
                    startIndex: offset
                )
            }
            playlistEntries.append(contentsOf: entries.enumerated().map { position, item in
                LibraryPlaylistEntry(
                    playlistID: playlist.Id,
                    track: Track(from: item, baseURL: baseURL),
                    position: position
                )
            })
        }

        let userData = Self.userDataChanges(from: userItems)
        status = .syncing(message: "Applying library changes…", progress: 0.96)
        let delta = LibraryDelta(
            albums: Self.unique(albums),
            artists: Self.unique(artists),
            tracks: Self.unique(tracks),
            playlists: Self.unique(playlists),
            userData: userData,
            refreshedPlaylistIDs: Set(playlistItemsToRefresh.map(\.Id)),
            playlistEntries: playlistEntries,
            removedItemIDs: removedIDs,
            replacementArtists: replacementArtists,
            replacementGenres: replacementGenres,
            metadataWatermark: syncStartedAt,
            userDataWatermark: syncStartedAt,
            reconciledAt: reconcile ? syncStartedAt : nil
        )
        let commit = try await repository.applyDelta(delta, in: scope)
        if commit.changed {
            PhoneConnectivityManager.shared.syncLibraryDeltaToWatch(
                delta,
                commit: commit,
                scope: scope
            )
        }
    }

    private static func unique<T: Identifiable>(_ values: [T]) -> [T] where T.ID == String {
        var positions: [String: Int] = [:]
        var result: [T] = []
        for value in values {
            if let position = positions[value.id] {
                result[position] = value
            } else {
                positions[value.id] = result.count
                result.append(value)
            }
        }
        return result
    }

    private static func userDataChanges(from items: [BaseItemDto]) -> [LibraryUserDataChange] {
        items.compactMap { item in
            guard let value = item.UserData else { return nil }
            return LibraryUserDataChange(
                itemID: item.Id,
                isFavorite: value.IsFavorite,
                lastPlayedAt: value.lastPlayedDate,
                playCount: value.PlayCount,
                playbackPositionTicks: value.PlaybackPositionTicks
            )
        }
    }

    private func allPages(
        label: String,
        progressRange: ClosedRange<Double>,
        fetch: @escaping (_ limit: Int, _ offset: Int) async throws -> ItemsResponse
    ) async throws -> [BaseItemDto] {
        var offset = 0
        var result: [BaseItemDto] = []
        var seen = Set<String>()
        var expectedTotal = 0

        while true {
            try Task.checkCancellation()
            let initialFraction = expectedTotal > 0
                ? min(Double(offset) / Double(expectedTotal), 1)
                : 0
            updateProgress(
                label: label,
                completed: min(offset, expectedTotal),
                total: expectedTotal,
                fraction: initialFraction,
                range: progressRange
            )

            let page = try await fetchPageWithRetry {
                try await fetch(self.pageSize, offset)
            }
            expectedTotal = max(expectedTotal, page.TotalRecordCount)
            for item in page.Items where seen.insert(item.Id).inserted {
                result.append(item)
            }
            let completed = expectedTotal > 0
                ? min(offset + pageSize, expectedTotal)
                : result.count
            let fraction = expectedTotal > 0
                ? min(Double(completed) / Double(expectedTotal), 1)
                : (page.Items.count < pageSize ? 1 : 0)
            updateProgress(
                label: label,
                completed: completed,
                total: expectedTotal,
                fraction: fraction,
                range: progressRange
            )

            if expectedTotal > 0 {
                offset += pageSize
                guard offset < expectedTotal else { break }
            } else {
                guard page.Items.count == pageSize else { break }
                offset += page.Items.count
            }
        }
        return result
    }

    private func fetchPageWithRetry(
        _ fetch: () async throws -> ItemsResponse
    ) async throws -> ItemsResponse {
        var attempt = 0
        while true {
            do {
                return try await fetch()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                attempt += 1
                guard attempt < 3, isTransientNetworkError(error) else { throw error }
                try await Task.sleep(for: .milliseconds(500 * attempt))
            }
        }
    }

    private func isTransientNetworkError(_ error: Error) -> Bool {
        let error = error as NSError
        guard error.domain == NSURLErrorDomain else { return false }
        return [
            NSURLErrorTimedOut,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorCannotConnectToHost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorNotConnectedToInternet
        ].contains(error.code)
    }

    private func updateProgress(
        label: String,
        completed: Int,
        total: Int,
        fraction: Double,
        range: ClosedRange<Double>
    ) {
        let progress = range.lowerBound + (range.upperBound - range.lowerBound) * fraction
        let count = total > 0 ? " \(completed) of \(total)" : ""
        status = .syncing(
            message: "Syncing \(label)…\(count)",
            progress: min(max(progress, 0), 1)
        )
    }
}

/// Observable, cache-only metadata facade used by SwiftUI. Server access is
/// deliberately confined to LibrarySyncCoordinator.
@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore(
        service: .shared,
        repository: .shared,
        coordinator: .shared
    )

    @Published private(set) var albums: [Album] = []
    @Published private(set) var artists: [Artist] = []
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var genres: [Genre] = []
    @Published private(set) var recentAlbums: [Album] = []
    @Published private(set) var isInitialLoading = true
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var syncMessage: String?
    @Published private(set) var syncProgress: Double?

    private let service: JellyfinService
    private let repository: LibraryRepository
    private let coordinator: LibrarySyncCoordinator
    private var activeScope: LibraryScope?
    private var launchedScopes = Set<LibraryScope>()
    private var cancellables = Set<AnyCancellable>()

    init(
        service: JellyfinService,
        repository: LibraryRepository,
        coordinator: LibrarySyncCoordinator
    ) {
        self.service = service
        self.repository = repository
        self.coordinator = coordinator

        coordinator.$status
            .sink { [weak self] status in
                switch status {
                case .idle:
                    self?.syncMessage = nil
                    self?.syncProgress = nil
                case .syncing(let message, let progress):
                    self?.syncMessage = message
                    self?.syncProgress = progress
                case .failed:
                    self?.syncProgress = nil
                }
            }
            .store(in: &cancellables)
    }

    func activate() async {
        guard let scope = service.libraryScope else {
            clear()
            return
        }

        if activeScope != scope {
            activeScope = scope
            await repository.importLegacyCacheIfNeeded(in: scope)
            await reload(in: scope)
        }

        guard launchedScopes.insert(scope).inserted else { return }
        if isInitialLoading {
            await refresh(trigger: .launch)
        } else {
            Task { @MainActor [weak self] in
                await self?.refresh(trigger: .launch)
            }
        }
    }

    func refresh(trigger: LibrarySyncTrigger = .pullToRefresh) async {
        guard let scope = service.libraryScope else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            isInitialLoading = false
        }

        do {
            try await coordinator.sync(trigger: trigger)
            errorMessage = nil
            await reload(in: scope)
        } catch is CancellationError {
            // Navigating away while a refresh is in flight is benign. The old
            // complete database snapshot remains visible.
        } catch {
            errorMessage = error.localizedDescription
            await reload(in: scope)
        }
    }

    func reload() async {
        guard let scope = activeScope ?? service.libraryScope else { return }
        await reload(in: scope)
    }

    func rebuild() async {
        await refresh(trigger: .rebuild)
    }

    func albums(inGenre genreID: String) async -> [Album] {
        guard let scope = activeScope ?? service.libraryScope else { return [] }
        return (try? await repository.albums(inGenre: genreID, in: scope)) ?? []
    }

    private func reload(in scope: LibraryScope) async {
        guard let snapshot = try? await repository.librarySnapshot(
            in: scope,
            includeTracks: false
        ) else {
            isInitialLoading = true
            return
        }
        albums = snapshot.albums
        artists = snapshot.artists
        // Tracks stay query-backed. Loading tens of thousands of rows into an
        // observable array made every routine sync needlessly expensive.
        tracks = []
        playlists = snapshot.playlists
        genres = snapshot.genres
        recentAlbums = await repository.cachedRecentAlbums(in: scope, limit: 40)
        isInitialLoading = !snapshot.hasCachedLibrary
    }

    private func clear() {
        activeScope = nil
        albums = []
        artists = []
        tracks = []
        playlists = []
        genres = []
        recentAlbums = []
        errorMessage = nil
        syncMessage = nil
        syncProgress = nil
        isInitialLoading = true
        isRefreshing = false
    }
}
