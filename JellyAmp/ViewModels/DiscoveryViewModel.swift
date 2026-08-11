//
//  DiscoveryViewModel.swift
//  JellyAmp
//
//  Persisted recommendation shelves backed by Jellyfin Instant Mix.
//

import Foundation
import Combine
import OSLog

nonisolated struct DiscoveryShelf: Identifiable, Codable, Equatable, Sendable {
    let seed: Track
    let tracks: [Track]

    var id: String { seed.id }

    var mixTitle: String {
        "\(seed.artistName) Mix"
    }

    var supportingArtistNames: [String] {
        let mainArtist = seed.artistName.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()

        let otherArtists = tracks.compactMap { track -> String? in
            let artist = track.artistName.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = artist.lowercased()
            guard !artist.isEmpty,
                  key != mainArtist.lowercased(),
                  seen.insert(key).inserted else {
                return nil
            }
            return artist
        }

        return otherArtists.isEmpty && !mainArtist.isEmpty ? [mainArtist] : otherArtists
    }
}

nonisolated struct DiscoverySnapshot: Codable, Equatable, Sendable {
    let shelves: [DiscoveryShelf]
    let fallbackTracks: [Track]
    let recentTracks: [Track]?
    let recentSignature: [String]
    let refreshedAt: Date
}

struct DiscoveryCache {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String) {
        self.defaults = defaults
        self.key = key
    }

    static func key(baseURL: String, userId: String?) -> String {
        let identity = "\(baseURL.lowercased())|\(userId ?? "")"
        let encodedIdentity = Data(identity.utf8).base64EncodedString()
        return "discoverySnapshot.v2.\(encodedIdentity)"
    }

    func load() -> DiscoverySnapshot? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(DiscoverySnapshot.self, from: data)
    }

    func save(_ snapshot: DiscoverySnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }
}

@MainActor
final class DiscoveryViewModel: ObservableObject {
    static let maximumMixShelfCount = 10

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "JellyAmp",
        category: "Discovery"
    )

    @Published private(set) var shelves: [DiscoveryShelf] = []
    @Published private(set) var fallbackTracks: [Track] = []
    @Published private(set) var recentTracks: [Track] = []
    @Published private(set) var availability: AudioMuseAvailability = .checking
    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshing = false
    @Published var errorMessage: String?

    private let api: any DiscoveryAPI
    private let recentTracksProvider: () -> [Track]
    private let recentCache: (any RecentTrackCaching)?
    private let recentScope: LibraryScope?
    private let cache: DiscoveryCache?
    private let snapshotRepository: LibraryRepository?
    private let snapshotScope: LibraryScope?
    private var hasLoadedDatabaseCache = false
    private var loadedRecentSignature: [String] = []
    private var lastRefreshDate: Date?
    private var pendingSnapshot: DiscoverySnapshot?
    private var isPreparingRefresh = false
    private var refreshGeneration: UInt64 = 0
    private var observedActiveAnalysis = false
    private let cacheMaxAge: TimeInterval = 5 * 60

    convenience init() {
        let service = JellyfinService.shared
        self.init(
            api: service,
            recentTracksProvider: { PlayerManager.shared.recentlyPlayedTracks },
            recentCache: LibraryRepository.shared,
            recentScope: service.libraryScope,
            snapshotRepository: LibraryRepository.shared,
            snapshotScope: service.libraryScope,
            cache: DiscoveryCache(
                key: DiscoveryCache.key(
                    baseURL: service.baseURL,
                    userId: service.currentUserId
                )
            )
        )
    }

    init(
        api: any DiscoveryAPI,
        recentTracksProvider: @escaping () -> [Track],
        recentCache: (any RecentTrackCaching)? = nil,
        recentScope: LibraryScope? = nil,
        snapshotRepository: LibraryRepository? = nil,
        snapshotScope: LibraryScope? = nil,
        cache: DiscoveryCache? = nil
    ) {
        self.api = api
        self.recentTracksProvider = recentTracksProvider
        self.recentCache = recentCache
        self.recentScope = recentScope
        self.snapshotRepository = snapshotRepository
        self.snapshotScope = snapshotScope
        self.cache = cache
        recentTracks = Self.uniqueRecentTracks(recentTracksProvider())

        if let snapshot = cache?.load() {
            shelves = snapshot.shelves
            recentTracks = snapshot.recentTracks ?? recentTracks
            fallbackTracks = recentTracks.isEmpty ? snapshot.fallbackTracks : []
            loadedRecentSignature = snapshot.recentSignature
            lastRefreshDate = snapshot.refreshedAt
        }
    }

    var hasContent: Bool {
        !shelves.isEmpty || !fallbackTracks.isEmpty || !recentTracks.isEmpty
    }

    func activate() async {
        if !hasLoadedDatabaseCache {
            hasLoadedDatabaseCache = true
            if let snapshotRepository,
               let snapshotScope,
               let stored = await snapshotRepository.discoverySnapshot(in: snapshotScope),
               lastRefreshDate == nil || stored.refreshedAt >= (lastRefreshDate ?? .distantPast) {
                apply(stored)
            }
        }

        // Adopt recommendations prepared during the previous visit before the
        // page becomes interactive. Automatic refreshes then stage their result
        // for the next visit so shelves never reorder under the user's finger.
        applyPendingSnapshot()
        let needsInitialRecommendations = shelves.isEmpty && fallbackTracks.isEmpty
        await loadIfNeeded(publishResult: needsInitialRecommendations)
        await updateAudioMuseStatus()

        while !Task.isCancelled {
            guard case .analyzing = availability else { return }
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            await updateAudioMuseStatus()
        }
    }

    func loadIfNeeded(publishResult: Bool = true) async {
        let signature = Self.uniqueRecentTracks(recentTracksProvider()).prefix(12).map(\.id)
        let freshestSignature = pendingSnapshot?.recentSignature ?? loadedRecentSignature
        let freshestRefreshDate = pendingSnapshot?.refreshedAt ?? lastRefreshDate
        let cacheIsStale = freshestRefreshDate.map {
            Date().timeIntervalSince($0) >= cacheMaxAge
        } ?? true
        guard !hasContent || signature != freshestSignature || cacheIsStale else { return }
        await refresh(force: true, publishResult: publishResult)
    }

    func refresh(force: Bool = true, publishResult: Bool = true) async {
        guard force || !hasContent else { return }
        guard !isLoading && !isRefreshing else { return }
        guard publishResult || !isPreparingRefresh else { return }

        // A user-initiated refresh supersedes any automatic preparation already
        // in flight. The older result is discarded when it completes.
        refreshGeneration &+= 1
        let generation = refreshGeneration

        if publishResult {
            let retainingContent = hasContent
            if retainingContent {
                isRefreshing = true
            } else {
                isLoading = true
            }
        } else {
            isPreparingRefresh = true
        }
        defer {
            if publishResult {
                isLoading = false
                isRefreshing = false
            } else {
                isPreparingRefresh = false
            }
        }

        do {
            let previousShelves = shelves
            let recentTracks = try await fetchRecentlyPlayedTracks()
            let recent = uniqueSeeds(recentTracks)
            async let favoriteTracks = fetchFavoriteSeedTracks()
            async let randomTracks = fetchRandomSeedTracks()
            let fetchedSeeds = try await (favoriteTracks, randomTracks)
            let candidates = uniqueSeeds(recent + fetchedSeeds.0 + fetchedSeeds.1)

            var newShelves: [DiscoveryShelf] = []
            var usedRecommendationIds = Set<String>()
            var mixFailures: [String] = []
            var emptyMixCount = 0

            for seed in candidates.prefix(12) where newShelves.count < Self.maximumMixShelfCount {
                do {
                    try Task.checkCancellation()
                    let items = try await api.fetchInstantMix(itemId: seed.id, limit: 13)
                    try Task.checkCancellation()
                    let tracks = items
                        .filter { $0.Type == .Audio && $0.Id != seed.id }
                        .map { Track(from: $0, baseURL: api.baseURL) }
                        .filter { usedRecommendationIds.insert($0.id).inserted }
                    let recommendations = Array(tracks.prefix(12))
                    if !recommendations.isEmpty {
                        newShelves.append(DiscoveryShelf(seed: seed, tracks: recommendations))
                    } else {
                        emptyMixCount += 1
                        Self.logger.info(
                            "Instant Mix returned no recommendations for seed \(seed.id, privacy: .private(mask: .hash))"
                        )
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    mixFailures.append(error.localizedDescription)
                    Self.logger.warning(
                        "Instant Mix failed for seed \(seed.id, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .public)"
                    )
                    continue
                }
            }

            guard !newShelves.isEmpty || !candidates.isEmpty else {
                throw DiscoveryError.noMusic
            }

            // A refresh is transactional for recommendation shelves. Recent
            // playback can still move forward, but a temporary plugin/server
            // failure must never replace known-good mixes with an empty array.
            let resolvedShelves = newShelves.isEmpty ? previousShelves : newShelves
            let fallbackTracks = resolvedShelves.isEmpty && recentTracks.isEmpty
                ? Array(candidates.prefix(12))
                : []
            let snapshot = DiscoverySnapshot(
                shelves: resolvedShelves,
                fallbackTracks: fallbackTracks,
                recentTracks: Array(recentTracks.prefix(12)),
                recentSignature: Array(recentTracks.prefix(12).map(\.id)),
                refreshedAt: Date()
            )
            let mixIssue = mixRefreshIssue(
                candidatesWereAvailable: !candidates.isEmpty,
                generatedShelfCount: newShelves.count,
                retainedPreviousShelves: newShelves.isEmpty && !previousShelves.isEmpty,
                failureDescriptions: mixFailures,
                emptyMixCount: emptyMixCount
            )

            guard generation == refreshGeneration else { return }

            if publishResult {
                pendingSnapshot = nil
                apply(snapshot)
                errorMessage = mixIssue
            } else {
                pendingSnapshot = snapshot
            }
            cache?.save(snapshot)
            if let snapshotRepository, let snapshotScope {
                await snapshotRepository.saveDiscoverySnapshot(snapshot, in: snapshotScope)
            }
        } catch is CancellationError {
            return
        } catch {
            if publishResult {
                errorMessage = error.localizedDescription
            }
        }
    }

    func updateAudioMuseStatus() async {
        do {
            let info = try await api.fetchAudioMuseInfo()
            let healthy = try await api.checkAudioMuseHealth()
            guard healthy else {
                availability = .unavailable
                return
            }

            if let task = try await api.fetchActiveAudioMuseTask() {
                observedActiveAnalysis = true
                availability = .analyzing(task)
            } else {
                availability = .ready(version: info.version)
                if observedActiveAnalysis {
                    observedActiveAnalysis = false
                    await refresh(force: true, publishResult: false)
                }
            }
        } catch let error as JellyfinError {
            if case .notFound = error {
                availability = .notInstalled
            } else {
                availability = .unavailable
            }
        } catch {
            availability = .unavailable
        }
    }

    private static func uniqueRecentTracks(_ tracks: [Track]) -> [Track] {
        var itemIds = Set<String>()
        return tracks.filter { itemIds.insert($0.id).inserted }
    }

    private func fetchRecentlyPlayedTracks() async throws -> [Track] {
        do {
            let items = try await api.fetchRecentlyPlayedTracks(limit: 20)
            let tracks = Self.uniqueRecentTracks(
                items
                    .filter { $0.Type == .Audio }
                    .map { Track(from: $0, baseURL: api.baseURL) }
            )
            if let recentCache, let recentScope {
                await recentCache.replaceRecentlyPlayed(
                    recentTrackEntries(from: items, baseURL: api.baseURL),
                    in: recentScope
                )
            }
            return tracks
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Preserve useful offline behavior without treating one device's
            // local history as authoritative when Jellyfin is reachable.
            let local = Self.uniqueRecentTracks(recentTracksProvider())
            if !local.isEmpty { return local }
            if let recentCache, let recentScope {
                return Self.uniqueRecentTracks(
                    await recentCache.cachedRecentTracks(in: recentScope, limit: 20)
                )
            }
            return []
        }
    }

    private func fetchFavoriteSeedTracks() async throws -> [Track] {
        do {
            return try await api.fetchFavoriteTracks(limit: 12)
                .map { Track(from: $0, baseURL: api.baseURL) }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return []
        }
    }

    private func fetchRandomSeedTracks() async throws -> [Track] {
        do {
            return try await api.fetchRandomTracks(limit: 12)
                .map { Track(from: $0, baseURL: api.baseURL) }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return []
        }
    }

    private func mixRefreshIssue(
        candidatesWereAvailable: Bool,
        generatedShelfCount: Int,
        retainedPreviousShelves: Bool,
        failureDescriptions: [String],
        emptyMixCount: Int
    ) -> String? {
        guard candidatesWereAvailable, generatedShelfCount == 0,
              !failureDescriptions.isEmpty || emptyMixCount > 0 else {
            return nil
        }

        let summary = retainedPreviousShelves
            ? "Couldn’t refresh Instant Mixes. Showing the previous mixes."
            : "Instant Mixes are temporarily unavailable."
        guard let detail = failureDescriptions.first else { return summary }
        return "\(summary) \(detail)"
    }

    private func uniqueSeeds(_ tracks: [Track]) -> [Track] {
        var itemIds = Set<String>()
        var artistKeys = Set<String>()

        return tracks.filter { track in
            let artistKey = track.artistId?.lowercased()
                ?? track.artistName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return itemIds.insert(track.id).inserted && artistKeys.insert(artistKey).inserted
        }
    }

    private func applyPendingSnapshot() {
        guard let pendingSnapshot else { return }
        apply(pendingSnapshot)
        self.pendingSnapshot = nil
        errorMessage = nil
    }

    private func apply(_ snapshot: DiscoverySnapshot) {
        shelves = snapshot.shelves
        recentTracks = snapshot.recentTracks ?? recentTracks
        fallbackTracks = recentTracks.isEmpty ? snapshot.fallbackTracks : []
        loadedRecentSignature = snapshot.recentSignature
        lastRefreshDate = snapshot.refreshedAt
    }
}

private enum DiscoveryError: LocalizedError {
    case noMusic

    var errorDescription: String? {
        "No music is available for recommendations yet."
    }
}
