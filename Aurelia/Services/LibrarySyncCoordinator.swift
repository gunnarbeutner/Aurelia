import Foundation
import Combine

enum LibrarySyncTrigger: Sendable {
    case launch
    case pullToRefresh
    case manual
}

enum LibrarySyncStatus: Equatable, Sendable {
    case idle
    case syncing(message: String, progress: Double)
    case failed(message: String, hasCachedLibrary: Bool)
}

/// Performs complete, paged Jellyfin reconciliations. The repository is only
/// replaced after every page and playlist entry has arrived successfully, so
/// cancellation or a network error can never expose a partially synced library.
@MainActor
final class LibrarySyncCoordinator: ObservableObject {
    static let shared = LibrarySyncCoordinator(
        service: .shared,
        repository: .shared
    )

    @Published private(set) var status: LibrarySyncStatus = .idle

    private let service: JellyfinService
    private let repository: LibraryRepository
    private var activeTask: Task<Void, Error>?
    private let pageSize = 500

    init(
        service: JellyfinService,
        repository: LibraryRepository
    ) {
        self.service = service
        self.repository = repository
    }

    func sync(trigger: LibrarySyncTrigger) async throws {
        if let activeTask {
            try await activeTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
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
            let albumItems = try await allPages(
                label: "albums",
                progressRange: 0.02...0.14
            ) { limit, offset in
                try await self.service.fetchMusicItemsPage(
                    includeItemTypes: "MusicAlbum",
                    limit: limit,
                    startIndex: offset
                )
            }

            try Task.checkCancellation()
            let artistItems = try await allPages(
                label: "artists",
                progressRange: 0.14...0.25
            ) { limit, offset in
                try await self.service.fetchArtistsPage(limit: limit, startIndex: offset)
            }

            try Task.checkCancellation()
            let trackItems = try await allPages(
                label: "tracks",
                progressRange: 0.25...0.67
            ) { limit, offset in
                try await self.service.fetchMusicItemsPage(
                    includeItemTypes: "Audio",
                    limit: limit,
                    startIndex: offset
                )
            }

            try Task.checkCancellation()
            let playlistItems = try await allPages(
                label: "playlists",
                progressRange: 0.67...0.73
            ) { limit, offset in
                try await self.service.fetchPlaylistsPage(limit: limit, startIndex: offset)
            }

            try Task.checkCancellation()
            let genreItems = try await allPages(
                label: "genres",
                progressRange: 0.73...0.78
            ) { limit, offset in
                try await self.service.fetchGenresPage(limit: limit, startIndex: offset)
            }

            let baseURL = service.baseURL
            var playlistEntries: [LibraryPlaylistEntry] = []
            for (playlistIndex, playlistItem) in playlistItems.enumerated() {
                try Task.checkCancellation()
                let playlistCount = max(playlistItems.count, 1)
                let rangeStart = 0.78 + 0.17 * Double(playlistIndex) / Double(playlistCount)
                let rangeEnd = 0.78 + 0.17 * Double(playlistIndex + 1) / Double(playlistCount)
                let entries = try await allPages(
                    label: "playlist \(playlistIndex + 1) of \(playlistItems.count)",
                    progressRange: rangeStart...rangeEnd
                ) { limit, offset in
                    try await self.service.fetchTracksPage(
                        parentId: playlistItem.Id,
                        limit: limit,
                        startIndex: offset
                    )
                }
                playlistEntries.append(contentsOf: entries.enumerated().map { position, item in
                    LibraryPlaylistEntry(
                        playlistID: playlistItem.Id,
                        track: Track(from: item, baseURL: baseURL),
                        position: position
                    )
                })
            }

            try Task.checkCancellation()
            status = .syncing(message: "Updating local library…", progress: 0.96)
            let catalog = LibraryCatalog(
                albums: albumItems.map { Album(from: $0, baseURL: baseURL) },
                artists: artistItems.map { Artist(from: $0, baseURL: baseURL) },
                tracks: trackItems.map { Track(from: $0, baseURL: baseURL) },
                playlists: playlistItems.map { Playlist(from: $0, baseURL: baseURL) },
                genres: genreItems.map(Genre.init(from:)),
                playlistEntries: playlistEntries
            )
            try await repository.replaceCompleteLibrary(catalog, in: scope)

            // Cross-client recency is a small, independently refreshed window.
            // A failure here must not invalidate the complete catalog commit.
            if let recentItems = try? await service.fetchRecentlyPlayedTracks(limit: 100) {
                status = .syncing(message: "Updating recent plays…", progress: 0.99)
                await repository.replaceRecentlyPlayed(
                    recentTrackEntries(from: recentItems, baseURL: baseURL),
                    in: scope
                )
            }
            status = .idle
        } catch is CancellationError {
            status = .idle
            throw CancellationError()
        } catch {
            let hasCache = (try? await repository.librarySnapshot(in: scope).hasCachedLibrary) ?? false
            status = .failed(message: error.localizedDescription, hasCachedLibrary: hasCache)
            throw error
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

    func albums(inGenre genreID: String) async -> [Album] {
        guard let scope = activeScope ?? service.libraryScope else { return [] }
        return (try? await repository.albums(inGenre: genreID, in: scope)) ?? []
    }

    private func reload(in scope: LibraryScope) async {
        guard let snapshot = try? await repository.librarySnapshot(in: scope) else {
            isInitialLoading = true
            return
        }
        albums = snapshot.albums
        artists = snapshot.artists
        tracks = snapshot.tracks
        playlists = snapshot.playlists
        genres = snapshot.genres
        recentAlbums = await repository.cachedRecentAlbums(in: scope, limit: 40)
        isInitialLoading = !snapshot.hasCachedLibrary
        PhoneConnectivityManager.shared.syncLibrarySnapshotToWatch(
            snapshot: snapshot,
            scope: scope
        )
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
