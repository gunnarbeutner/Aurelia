import Foundation
import Combine

enum LibrarySyncTrigger: Sendable {
    case launch
    case pullToRefresh
    case manual
}

enum LibrarySyncStatus: Equatable, Sendable {
    case idle
    case syncing(message: String)
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
            status = .syncing(message: "Syncing albums…")
            let albumItems = try await allPages { limit, offset in
                try await self.service.fetchMusicItems(
                    includeItemTypes: "MusicAlbum",
                    limit: limit,
                    startIndex: offset
                )
            }

            try Task.checkCancellation()
            status = .syncing(message: "Syncing artists…")
            let artistItems = try await allPages { limit, offset in
                try await self.service.fetchArtists(limit: limit, startIndex: offset)
            }

            try Task.checkCancellation()
            status = .syncing(message: "Syncing tracks…")
            let trackItems = try await allPages { limit, offset in
                try await self.service.fetchMusicItems(
                    includeItemTypes: "Audio",
                    limit: limit,
                    startIndex: offset
                )
            }

            try Task.checkCancellation()
            status = .syncing(message: "Syncing playlists…")
            let playlistItems = try await allPages { limit, offset in
                try await self.service.fetchPlaylists(limit: limit, startIndex: offset)
            }

            try Task.checkCancellation()
            status = .syncing(message: "Syncing genres…")
            let genreItems = try await allPages { limit, offset in
                try await self.service.fetchGenres(limit: limit, startIndex: offset)
            }

            let baseURL = service.baseURL
            var playlistEntries: [LibraryPlaylistEntry] = []
            for (playlistIndex, playlistItem) in playlistItems.enumerated() {
                try Task.checkCancellation()
                status = .syncing(
                    message: "Syncing playlist \(playlistIndex + 1) of \(playlistItems.count)…"
                )
                let entries = try await allPages { limit, offset in
                    try await self.service.fetchTracks(
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
            status = .syncing(message: "Updating local library…")
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
        fetch: @escaping (_ limit: Int, _ offset: Int) async throws -> [BaseItemDto]
    ) async throws -> [BaseItemDto] {
        var offset = 0
        var result: [BaseItemDto] = []
        var seen = Set<String>()

        while true {
            try Task.checkCancellation()
            let page = try await fetch(pageSize, offset)
            for item in page where seen.insert(item.Id).inserted {
                result.append(item)
            }
            guard page.count == pageSize else { break }
            offset += page.count
        }
        return result
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

    private let service: JellyfinService
    private let repository: LibraryRepository
    private let coordinator: LibrarySyncCoordinator
    private var activeScope: LibraryScope?
    private var launchedScopes = Set<LibraryScope>()

    init(
        service: JellyfinService,
        repository: LibraryRepository,
        coordinator: LibrarySyncCoordinator
    ) {
        self.service = service
        self.repository = repository
        self.coordinator = coordinator
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
        isInitialLoading = true
        isRefreshing = false
    }
}
