import Foundation
import Combine

struct FavoritesSnapshot: Equatable {
    var tracks: [Track]
    var albums: [Album]
    var artists: [Artist]

    static let empty = FavoritesSnapshot(tracks: [], albums: [], artists: [])

    var isEmpty: Bool {
        tracks.isEmpty && albums.isEmpty && artists.isEmpty
    }
}

enum FavoriteMutation {
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
    }
}

@MainActor
final class FavoritesViewModel: ObservableObject {
    @Published private(set) var snapshot: FavoritesSnapshot = .empty
    @Published private(set) var isInitialLoading = true
    @Published private(set) var initialErrorMessage: String?
    @Published private(set) var revalidationErrorMessage: String?

    private let fetcher: () async throws -> FavoritesSnapshot
    private let now: () -> Date
    private let revisionProvider: () -> UInt64
    private let revalidationInterval: TimeInterval

    private var hasLoaded = false
    private var isStale = true
    private var lastValidatedAt: Date?
    private var fetchTask: Task<FavoritesSnapshot, Error>?

    convenience init() {
        let service = JellyfinService.shared
        self.init(
            revisionProvider: { FavoriteMutationCenter.shared.revision },
            fetcher: {
                let items = try await service.fetchFavorites(
                    includeItemTypes: "Audio,MusicAlbum,MusicArtist"
                )
                return Self.makeSnapshot(from: items, baseURL: service.baseURL)
            }
        )
    }

    init(
        revalidationInterval: TimeInterval = 5 * 60,
        now: @escaping () -> Date = Date.init,
        revisionProvider: @escaping () -> UInt64 = { 0 },
        fetcher: @escaping () async throws -> FavoritesSnapshot
    ) {
        self.revalidationInterval = revalidationInterval
        self.now = now
        self.revisionProvider = revisionProvider
        self.fetcher = fetcher
    }

    var tracks: [Track] { snapshot.tracks }
    var albums: [Album] { snapshot.albums }
    var artists: [Artist] { snapshot.artists }
    var isEmpty: Bool { snapshot.isEmpty }

    func activate() async {
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

    private static func makeSnapshot(from items: [BaseItemDto], baseURL: String) -> FavoritesSnapshot {
        var snapshot = FavoritesSnapshot.empty

        for item in items {
            switch item.Type {
            case .Audio:
                snapshot.tracks.append(Track(from: item, baseURL: baseURL))
            case .MusicAlbum:
                snapshot.albums.append(Album(from: item, baseURL: baseURL))
            case .MusicArtist:
                snapshot.artists.append(Artist(from: item, baseURL: baseURL))
            default:
                break
            }
        }

        snapshot.tracks.sort { $0.artistName.localizedCaseInsensitiveCompare($1.artistName) == .orderedAscending }
        snapshot.albums.sort { $0.artistName.localizedCaseInsensitiveCompare($1.artistName) == .orderedAscending }
        snapshot.artists.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return snapshot
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
