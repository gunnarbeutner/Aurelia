//
//  DiscoveryViewModel.swift
//  JellyAmp
//
//  Persisted recommendation shelves backed by Jellyfin Instant Mix.
//

import Foundation
import Combine

struct DiscoveryShelf: Identifiable, Codable, Equatable {
    let seed: Track
    let tracks: [Track]

    var id: String { seed.id }
}

struct DiscoverySnapshot: Codable, Equatable {
    let shelves: [DiscoveryShelf]
    let fallbackTracks: [Track]
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
        return "discoverySnapshot.v1.\(encodedIdentity)"
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
    @Published private(set) var shelves: [DiscoveryShelf] = []
    @Published private(set) var fallbackTracks: [Track] = []
    @Published private(set) var availability: AudioMuseAvailability = .checking
    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshing = false
    @Published var errorMessage: String?

    private let api: any DiscoveryAPI
    private let recentTracksProvider: () -> [Track]
    private let cache: DiscoveryCache?
    private var loadedRecentSignature: [String] = []
    private var lastRefreshDate: Date?
    private var observedActiveAnalysis = false
    private let cacheMaxAge: TimeInterval = 6 * 60 * 60

    convenience init() {
        let service = JellyfinService.shared
        self.init(
            api: service,
            recentTracksProvider: { PlayerManager.shared.recentlyPlayedTracks },
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
        cache: DiscoveryCache? = nil
    ) {
        self.api = api
        self.recentTracksProvider = recentTracksProvider
        self.cache = cache

        if let snapshot = cache?.load() {
            shelves = snapshot.shelves
            fallbackTracks = snapshot.fallbackTracks
            loadedRecentSignature = snapshot.recentSignature
            lastRefreshDate = snapshot.refreshedAt
        }
    }

    var hasContent: Bool {
        !shelves.isEmpty || !fallbackTracks.isEmpty
    }

    func activate() async {
        await loadIfNeeded()
        await updateAudioMuseStatus()

        while !Task.isCancelled {
            guard case .analyzing = availability else { return }
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            await updateAudioMuseStatus()
        }
    }

    func loadIfNeeded() async {
        let signature = recentSeedCandidates().prefix(3).map(\.id)
        let cacheIsStale = lastRefreshDate.map {
            Date().timeIntervalSince($0) >= cacheMaxAge
        } ?? true
        guard !hasContent || signature != loadedRecentSignature || cacheIsStale else { return }
        await refresh(force: true)
    }

    func refresh(force: Bool = true) async {
        guard force || !hasContent else { return }
        guard !isLoading && !isRefreshing else { return }

        let retainingContent = hasContent
        if retainingContent {
            isRefreshing = true
        } else {
            isLoading = true
        }
        defer {
            isLoading = false
            isRefreshing = false
        }

        do {
            let recent = recentSeedCandidates()
            async let favoriteTracks = fetchFavoriteSeedTracks()
            async let randomTracks = fetchRandomSeedTracks()
            let fetchedSeeds = await (favoriteTracks, randomTracks)
            let candidates = uniqueSeeds(recent + fetchedSeeds.0 + fetchedSeeds.1)

            var newShelves: [DiscoveryShelf] = []
            var usedRecommendationIds = Set<String>()

            for seed in candidates.prefix(12) where newShelves.count < 3 {
                do {
                    let items = try await api.fetchInstantMix(itemId: seed.id, limit: 13)
                    let tracks = items
                        .filter { $0.Type == .Audio && $0.Id != seed.id }
                        .map { Track(from: $0, baseURL: api.baseURL) }
                        .filter { usedRecommendationIds.insert($0.id).inserted }
                    let recommendations = Array(tracks.prefix(12))
                    if !recommendations.isEmpty {
                        newShelves.append(DiscoveryShelf(seed: seed, tracks: recommendations))
                    }
                } catch {
                    // A single unanalyzed seed must not prevent other shelves loading.
                    continue
                }
            }

            guard !newShelves.isEmpty || !candidates.isEmpty else {
                throw DiscoveryError.noMusic
            }

            shelves = newShelves
            fallbackTracks = newShelves.isEmpty ? Array(candidates.prefix(12)) : []
            loadedRecentSignature = Array(recent.prefix(3).map(\.id))
            lastRefreshDate = Date()
            errorMessage = nil
            saveSnapshot()
        } catch {
            errorMessage = error.localizedDescription
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
                    await refresh(force: true)
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

    private func recentSeedCandidates() -> [Track] {
        uniqueSeeds(recentTracksProvider())
    }

    private func fetchFavoriteSeedTracks() async -> [Track] {
        do {
            return try await api.fetchFavoriteTracks(limit: 12)
                .map { Track(from: $0, baseURL: api.baseURL) }
        } catch {
            return []
        }
    }

    private func fetchRandomSeedTracks() async -> [Track] {
        do {
            return try await api.fetchRandomTracks(limit: 12)
                .map { Track(from: $0, baseURL: api.baseURL) }
        } catch {
            return []
        }
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

    private func saveSnapshot() {
        guard let lastRefreshDate else { return }
        cache?.save(
            DiscoverySnapshot(
                shelves: shelves,
                fallbackTracks: fallbackTracks,
                recentSignature: loadedRecentSignature,
                refreshedAt: lastRefreshDate
            )
        )
    }
}

private enum DiscoveryError: LocalizedError {
    case noMusic

    var errorDescription: String? {
        "No music is available for recommendations yet."
    }
}
