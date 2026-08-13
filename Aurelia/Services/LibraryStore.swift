import Foundation
import Combine

/// Observable, cache-only metadata facade used by SwiftUI. AureliaSync is the
/// sole source of catalog synchronization; browsing never falls back to live
/// Jellyfin catalog queries.
@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore(service: .shared, repository: .shared, coordinator: .shared)

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
    @Published private(set) var hasCachedLibrary = false
    @Published private(set) var catalogRevision: Int64 = 0

    private let service: JellyfinService
    private let repository: LibraryRepository
    private let coordinator: LibrarySyncCoordinator
    private var activeScope: LibraryScope?
    private var launchedScopes = Set<LibraryScope>()
    private var cancellables = Set<AnyCancellable>()

    init(service: JellyfinService, repository: LibraryRepository, coordinator: LibrarySyncCoordinator) {
        self.service = service
        self.repository = repository
        self.coordinator = coordinator
        coordinator.$status.sink { [weak self] status in
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
        }.store(in: &cancellables)
    }

    func activate() async {
        guard let scope = service.libraryScope else { clear(); return }
        if activeScope != scope {
            activeScope = scope
            await repository.importLegacyCacheIfNeeded(in: scope)
            await reload(in: scope)
        }
        guard launchedScopes.insert(scope).inserted else { return }
        if isInitialLoading {
            await refresh(trigger: .launch)
        } else {
            Task { @MainActor [weak self] in await self?.refresh(trigger: .launch) }
        }
    }

    func refresh(trigger: LibrarySyncTrigger = .pullToRefresh) async {
        guard let scope = service.libraryScope else { return }
        errorMessage = nil
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await coordinator.sync(trigger: trigger)
            await reload(in: scope)
        } catch is CancellationError {
            // The previously promoted catalog stays visible.
        } catch {
            errorMessage = error.localizedDescription
            await reload(in: scope)
        }
    }

    func reload() async {
        guard let scope = activeScope ?? service.libraryScope else { return }
        await reload(in: scope)
    }

    func rebuild() async { await refresh(trigger: .rebuild) }

    func albums(inGenre genreID: String) async -> [Album] {
        guard let scope = activeScope ?? service.libraryScope else { return [] }
        return (try? await repository.albums(inGenre: genreID, in: scope)) ?? []
    }

    private func reload(in scope: LibraryScope) async {
        guard let snapshot = try? await repository.librarySnapshot(in: scope, includeTracks: false) else {
            isInitialLoading = true
            return
        }
        albums = snapshot.albums
        artists = snapshot.artists
        tracks = []
        playlists = snapshot.playlists
        genres = snapshot.genres
        recentAlbums = await repository.cachedRecentAlbums(in: scope, limit: 40)
        hasCachedLibrary = snapshot.hasCachedLibrary
        catalogRevision = snapshot.revision
        isInitialLoading = !hasCachedLibrary
    }

    private func clear() {
        activeScope = nil
        albums = []; artists = []; tracks = []; playlists = []; genres = []; recentAlbums = []
        errorMessage = nil; syncMessage = nil; syncProgress = nil
        hasCachedLibrary = false; catalogRevision = 0; isInitialLoading = true; isRefreshing = false
    }
}
