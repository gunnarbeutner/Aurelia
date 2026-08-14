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

    private let snapshotProvider: () async -> FavoritesSnapshot
    private let revisionProvider: () -> UInt64
    private var loadTask: Task<FavoritesSnapshot, Never>?

    convenience init() {
        self.init(
            revisionProvider: { FavoriteMutationCenter.shared.revision },
            snapshotProvider: {
                let service = JellyfinService.shared
                guard let scope = service.libraryScope else { return .empty }
                await LibraryRepository.shared.importLegacyCacheIfNeeded(in: scope)
                return await LibraryRepository.shared.favoriteSnapshot(in: scope)
            }
        )
    }

    init(
        revisionProvider: @escaping () -> UInt64 = { 0 },
        snapshotProvider: @escaping () async -> FavoritesSnapshot = { .empty }
    ) {
        self.revisionProvider = revisionProvider
        self.snapshotProvider = snapshotProvider
    }

    var tracks: [Track] { snapshot.tracks }
    var albums: [Album] { snapshot.albums }
    var artists: [Artist] { snapshot.artists }
    var isEmpty: Bool { snapshot.isEmpty }

    func activate() async {
        await reload()
    }

    func refresh() async {
        await reload()
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

    private func reload() async {
        if let loadTask {
            _ = await loadTask.value
            return
        }

        let startingRevision = revisionProvider()
        let task = Task { await snapshotProvider() }
        loadTask = task
        let loadedSnapshot = await task.value
        // An optimistic favorite mutation made while SQLite was being read is
        // newer than that read and must remain visible.
        if revisionProvider() == startingRevision {
            snapshot = loadedSnapshot
        }
        isInitialLoading = false
        loadTask = nil
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
