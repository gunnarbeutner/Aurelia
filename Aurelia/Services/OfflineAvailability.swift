//
//  OfflineAvailability.swift
//  Aurelia
//
//  Answers "will this still play with the server out of reach?" for the
//  browsing surfaces.
//

import Combine
import Foundation

/// Containers holding at least one downloaded track.
nonisolated struct OfflineContainerIDs: Equatable, Sendable {
    var albumIDs: Set<String> = []
    var artistIDs: Set<String> = []
    var playlistIDs: Set<String> = []
}

nonisolated enum OfflineSubject: Hashable, Sendable {
    case track(String)
    case album(String)
    case artist(String)
    case playlist(String)
}

/// A snapshot of what has a local copy. The sets hold one entry per downloaded
/// item, so they stay small enough for a row to consult during layout instead
/// of each row querying the database on its own.
nonisolated struct OfflineCatalog: Equatable, Sendable {
    var trackIDs: Set<String> = []
    var containers = OfflineContainerIDs()

    /// A container counts as available when *anything* inside it is downloaded.
    /// Partial albums stay undimmed and the dimming moves down to their tracks,
    /// which is where the distinction actually is.
    func hasLocalCopy(of subject: OfflineSubject) -> Bool {
        switch subject {
        case .track(let id): return trackIDs.contains(id)
        case .album(let id): return containers.albumIDs.contains(id)
        case .artist(let id): return containers.artistIDs.contains(id)
        case .playlist(let id): return containers.playlistIDs.contains(id)
        }
    }
}

final class OfflineAvailability: ObservableObject {
    static let shared = OfflineAvailability()

    @Published private(set) var isOffline = false
    @Published private(set) var catalog = OfflineCatalog()

    private let downloadManager: DownloadManager
    private let repository: LibraryRepository
    private let service: JellyfinService
    private let monitor: NetworkMonitor
    private var cancellables: Set<AnyCancellable> = []
    private var containerTask: Task<Void, Never>?
    private var isStarted = false

    init(
        downloadManager: DownloadManager = .shared,
        repository: LibraryRepository = .shared,
        service: JellyfinService = .shared,
        monitor: NetworkMonitor = .shared
    ) {
        self.downloadManager = downloadManager
        self.repository = repository
        self.service = service
        self.monitor = monitor
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        monitor.$isOffline
            .removeDuplicates()
            .sink { [weak self] offline in
                self?.isOffline = offline
            }
            .store(in: &cancellables)

        downloadManager.$downloadedTracks
            .sink { [weak self] downloads in
                self?.downloadsDidChange(downloads)
            }
            .store(in: &cancellables)
    }

    /// True when the user should be told this will not play right now. Online,
    /// nothing is marked — a library that is mostly not downloaded would
    /// otherwise read as mostly broken.
    func isUnavailable(_ subject: OfflineSubject) -> Bool {
        isOffline && !catalog.hasLocalCopy(of: subject)
    }

    private func downloadsDidChange(_ downloads: [DownloadedTrack]) {
        let trackIDs = Set(downloads.map(\.trackId))
        guard trackIDs != catalog.trackIDs else { return }

        // The download records already name an album and an artist, which
        // covers most of the library without waiting on a query.
        var resolved = OfflineCatalog(
            trackIDs: trackIDs,
            containers: OfflineContainerIDs(
                albumIDs: Set(downloads.map(\.albumId)),
                artistIDs: Set(downloads.compactMap(\.artistId))
            )
        )
        catalog = resolved

        containerTask?.cancel()
        containerTask = Task { [weak self] in
            guard let self, let scope = self.service.libraryScope else { return }
            guard let containers = try? await self.repository.offlineContainers(
                forTrackIDs: trackIDs,
                in: scope
            ) else { return }
            // A newer download change may have landed while the query ran.
            guard !Task.isCancelled, self.catalog.trackIDs == trackIDs else { return }
            resolved.containers.albumIDs.formUnion(containers.albumIDs)
            resolved.containers.artistIDs.formUnion(containers.artistIDs)
            resolved.containers.playlistIDs = containers.playlistIDs
            self.catalog = resolved
        }
    }
}
