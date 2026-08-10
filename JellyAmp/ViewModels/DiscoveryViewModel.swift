//
//  DiscoveryViewModel.swift
//  JellyAmp
//
//  Session-scoped recommendation shelves backed by Jellyfin Instant Mix.
//

import Foundation
import Combine

struct DiscoveryShelf: Identifiable, Equatable {
    let seed: Track
    let tracks: [Track]

    var id: String { seed.id }
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
    private var loadedRecentSignature: [String] = []
    private var observedActiveAnalysis = false

    convenience init() {
        self.init(
            api: JellyfinService.shared,
            recentTracksProvider: { PlayerManager.shared.recentlyPlayedTracks }
        )
    }

    init(api: any DiscoveryAPI, recentTracksProvider: @escaping () -> [Track]) {
        self.api = api
        self.recentTracksProvider = recentTracksProvider
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
        guard !hasContent || signature != loadedRecentSignature else { return }
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
            errorMessage = nil
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
}

private enum DiscoveryError: LocalizedError {
    case noMusic

    var errorDescription: String? {
        "No music is available for recommendations yet."
    }
}
