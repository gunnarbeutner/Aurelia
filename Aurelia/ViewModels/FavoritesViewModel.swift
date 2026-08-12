import Foundation
import Combine

nonisolated struct FavoritesSnapshot: Equatable, Sendable {
    var tracks: [Track]
    var albums: [Album]
    var artists: [Artist]

    static let empty = FavoritesSnapshot(tracks: [], albums: [], artists: [])

    var isEmpty: Bool {
        tracks.isEmpty && albums.isEmpty && artists.isEmpty
    }

    /// Groups the favourites Jellyfin returns into the snapshot shape. Anything
    /// that is not a track, album or artist — a favourited playlist, say — has
    /// nowhere to go in this view and is dropped.
    static func from(items: [BaseItemDto], baseURL: String) -> FavoritesSnapshot {
        var tracks: [Track] = []
        var albums: [Album] = []
        var artists: [Artist] = []

        for item in items {
            switch item.Type {
            case .Audio:
                tracks.append(Track(from: item, baseURL: baseURL))
            case .MusicAlbum:
                albums.append(Album(from: item, baseURL: baseURL))
            case .MusicArtist:
                artists.append(Artist(from: item, baseURL: baseURL))
            default:
                break
            }
        }

        return FavoritesSnapshot(tracks: tracks, albums: albums, artists: artists)
    }
}

nonisolated enum FavoriteMutation: Sendable {
    case track(Track, isFavorite: Bool)
    case album(Album, isFavorite: Bool)
    case artist(Artist, isFavorite: Bool)
}

@MainActor
final class FavoriteMutationCenter: ObservableObject {
    struct Event: Identifiable {
        let id = UUID()
        let mutation: FavoriteMutation
    }

    static let shared = FavoriteMutationCenter()

    @Published private(set) var latestEvent: Event?
    private(set) var revision: UInt64 = 0

    func publish(_ mutation: FavoriteMutation) {
        revision &+= 1
        latestEvent = Event(mutation: mutation)

        guard let scope = JellyfinService.shared.libraryScope else { return }
        Task {
            switch mutation {
            case .track(let track, let isFavorite):
                await LibraryRepository.shared.setFavorite(isFavorite, for: track, in: scope)
            case .album(let album, let isFavorite):
                await LibraryRepository.shared.setFavorite(isFavorite, for: album, in: scope)
            case .artist(let artist, let isFavorite):
                await LibraryRepository.shared.setFavorite(isFavorite, for: artist, in: scope)
            }
        }
    }
}

@MainActor
final class FavoritesViewModel: ObservableObject {
    @Published private(set) var snapshot: FavoritesSnapshot = .empty
    @Published private(set) var isInitialLoading = true
    @Published private(set) var initialErrorMessage: String?
    @Published private(set) var revalidationErrorMessage: String?

    private let fetcher: () async throws -> FavoritesSnapshot
    private let cachedSnapshotProvider: () async -> FavoritesSnapshot
    private let cacheSnapshot: (FavoritesSnapshot) async -> Void
    private let now: () -> Date
    private let revisionProvider: () -> UInt64
    private let revalidationInterval: TimeInterval

    private var hasLoaded = false
    private var hasLoadedCache = false
    private var isStale = true
    private var lastValidatedAt: Date?
    private var fetchTask: Task<FavoritesSnapshot, Error>?

    convenience init() {
        let service = JellyfinService.shared
        let scope = service.libraryScope
        self.init(
            revisionProvider: { FavoriteMutationCenter.shared.revision },
            cachedSnapshotProvider: {
                guard let scope else { return .empty }
                await LibraryRepository.shared.importLegacyCacheIfNeeded(in: scope)
                return await LibraryRepository.shared.favoriteSnapshot(in: scope)
            },
            cacheSnapshot: { _ in },
            fetcher: {
                // Favourites refresh on their own rather than dragging a whole
                // library sync behind them, which is what pull-to-refresh here
                // used to trigger.
                guard let currentScope = service.libraryScope else { return .empty }
                let items = try await service.fetchFavorites(
                    includeItemTypes: "Audio,MusicAlbum,MusicArtist"
                )
                await LibraryRepository.shared.replaceFavorites(
                    FavoritesSnapshot.from(items: items, baseURL: service.baseURL),
                    in: currentScope
                )
                return await LibraryRepository.shared.favoriteSnapshot(in: currentScope)
            }
        )
    }

    init(
        revalidationInterval: TimeInterval = 5 * 60,
        now: @escaping () -> Date = Date.init,
        revisionProvider: @escaping () -> UInt64 = { 0 },
        cachedSnapshotProvider: @escaping () async -> FavoritesSnapshot = { .empty },
        cacheSnapshot: @escaping (FavoritesSnapshot) async -> Void = { _ in },
        fetcher: @escaping () async throws -> FavoritesSnapshot
    ) {
        self.revalidationInterval = revalidationInterval
        self.now = now
        self.revisionProvider = revisionProvider
        self.cachedSnapshotProvider = cachedSnapshotProvider
        self.cacheSnapshot = cacheSnapshot
        self.fetcher = fetcher
    }

    var tracks: [Track] { snapshot.tracks }
    var albums: [Album] { snapshot.albums }
    var artists: [Artist] { snapshot.artists }
    var isEmpty: Bool { snapshot.isEmpty }

    func activate() async {
        if !hasLoadedCache {
            hasLoadedCache = true
            let cached = await cachedSnapshotProvider()
            if !cached.isEmpty {
                snapshot = cached
                hasLoaded = true
                isInitialLoading = false
            }
        }
        guard shouldRevalidate else { return }
        await load()
    }

    func refresh() async {
        await load()
    }

    func markStale() {
        isStale = true
    }

    func apply(_ mutation: FavoriteMutation) {
        switch mutation {
        case .track(var track, let isFavorite):
            track.isFavorite = isFavorite
            if isFavorite {
                snapshot.tracks.upsert(track)
            } else {
                snapshot.tracks.removeAll { $0.id == track.id }
            }
            snapshot.tracks.sort { $0.artistName.localizedCaseInsensitiveCompare($1.artistName) == .orderedAscending }

        case .album(var album, let isFavorite):
            album.isFavorite = isFavorite
            if isFavorite {
                snapshot.albums.upsert(album)
            } else {
                snapshot.albums.removeAll { $0.id == album.id }
            }
            snapshot.albums.sort { $0.artistName.localizedCaseInsensitiveCompare($1.artistName) == .orderedAscending }

        case .artist(var artist, let isFavorite):
            artist.isFavorite = isFavorite
            if isFavorite {
                snapshot.artists.upsert(artist)
            } else {
                snapshot.artists.removeAll { $0.id == artist.id }
            }
            snapshot.artists.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    private var shouldRevalidate: Bool {
        guard !isStale, let lastValidatedAt else { return true }
        return now().timeIntervalSince(lastValidatedAt) >= revalidationInterval
    }

    private func load() async {
        if let fetchTask {
            _ = try? await fetchTask.value
            return
        }

        let showsInitialLoader = !hasLoaded
        if showsInitialLoader {
            isInitialLoading = true
            initialErrorMessage = nil
        }
        revalidationErrorMessage = nil

        let startingRevision = revisionProvider()
        let task = Task { try await fetcher() }
        fetchTask = task

        do {
            let fetchedSnapshot = try await task.value
            if revisionProvider() == startingRevision {
                snapshot = fetchedSnapshot
                lastValidatedAt = now()
                isStale = false
                await cacheSnapshot(fetchedSnapshot)
            } else {
                // A successful local mutation landed while this request was in
                // flight. Keep the incrementally updated state instead of
                // allowing an older server response to resurrect stale items.
                isStale = true
            }
            hasLoaded = true
            isInitialLoading = false
            initialErrorMessage = nil
        } catch {
            hasLoaded = true
            isInitialLoading = false
            if snapshot.isEmpty {
                initialErrorMessage = error.localizedDescription
            } else {
                revalidationErrorMessage = error.localizedDescription
            }
        }

        fetchTask = nil
    }

}

private extension Array where Element: Identifiable {
    mutating func upsert(_ element: Element) where Element.ID: Equatable {
        if let index = firstIndex(where: { $0.id == element.id }) {
            self[index] = element
        } else {
            append(element)
        }
    }
}
