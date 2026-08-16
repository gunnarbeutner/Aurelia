//
//  DiscoveryViewModel.swift
//  Aurelia
//
//  Persisted recommendation shelves backed by Jellyfin Instant Mix.
//

import Foundation
import Combine
import OSLog

/// Decides which mixes lead the row.
nonisolated enum MixShelfOrdering {
    /// How many cards are in view before the row is scrolled.
    static let leadingCount = 3

    /// Moves mixes that have a cover to the front.
    ///
    /// A seed without artwork draws a waveform on a gradient. That is fine
    /// further along the row, but a screen that opens on three of them looks
    /// like the library failed to load rather than like a page of mixes.
    /// Order is otherwise left alone: these are recommendations, and shuffling
    /// them for looks would change what is being recommended.
    static func artworkFirst(_ shelves: [DiscoveryShelf]) -> [DiscoveryShelf] {
        var leading: [DiscoveryShelf] = []
        var rest: [DiscoveryShelf] = []

        for shelf in shelves {
            let hasArtwork = shelf.seed.artworkURL?.isEmpty == false
            if hasArtwork, leading.count < leadingCount {
                leading.append(shelf)
            } else {
                rest.append(shelf)
            }
        }

        return leading + rest
    }
}

nonisolated struct DiscoveryShelf: Identifiable, Codable, Equatable, Sendable {
    let seed: Track
    let tracks: [Track]
    var title: String? = nil

    var id: String { seed.id }

    var mixTitle: String {
        title ?? "\(seed.artistName) Mix"
    }

    /// What a mix plays, seed first.
    ///
    /// The card is the seed's artwork under the seed's name, so that is what
    /// pressing play has promised. The recommendations behind it have recent
    /// tracks filtered out, which usually excludes the seed itself, and
    /// starting there opens the mix on an artist the card never mentioned.
    var playbackTracks: [Track] {
        [seed] + tracks.filter { $0.id != seed.id }
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

nonisolated struct RecentPlayItem: Identifiable, Equatable, Sendable {
    let tracks: [Track]

    var resumeTrack: Track { tracks[0] }
    var albumID: String? { isAlbumSession ? resumeTrack.albumId : nil }
    var isAlbumSession: Bool { tracks.count > 1 && resumeTrack.albumId != nil }
    var id: String {
        isAlbumSession
            ? "album-session-\(resumeTrack.albumId!)-\(resumeTrack.id)"
            : "track-\(resumeTrack.id)"
    }
    var title: String { isAlbumSession ? resumeTrack.albumName : resumeTrack.name }
    var subtitle: String { resumeTrack.artistName }

    var album: Album? {
        guard let albumID else { return nil }
        return Album(
            id: albumID,
            name: resumeTrack.albumName,
            artistName: resumeTrack.artistName,
            artistId: resumeTrack.artistId,
            year: resumeTrack.productionYear,
            trackCount: nil,
            artworkURL: resumeTrack.artworkURL
        )
    }
}

nonisolated enum RecentPlayGrouping {
    /// Jellyfin exposes each track's latest play time rather than a true event
    /// stream, so apparent adjacency cannot identify listening sessions. Group
    /// every track with the same album ID and keep the group at the position of
    /// its newest member (the first one encountered in recency order).
    static func group(_ tracks: [Track]) -> [RecentPlayItem] {
        var groups: [[Track]] = []
        var albumGroupIndices: [String: Int] = [:]

        for track in tracks {
            if let albumID = track.albumId, let groupIndex = albumGroupIndices[albumID] {
                groups[groupIndex].append(track)
            } else {
                if let albumID = track.albumId {
                    albumGroupIndices[albumID] = groups.count
                }
                groups.append([track])
            }
        }

        return groups.map(RecentPlayItem.init(tracks:))
    }

    /// Retains enough raw history to render the requested number of cards.
    /// Applying a raw-track limit first can turn a shelf into a single card
    /// when the listener just played a long album.
    static func tracksForVisibleItems(_ tracks: [Track], limit: Int) -> [Track] {
        guard limit > 0 else { return [] }
        return group(tracks).prefix(limit).flatMap(\.tracks)
    }
}

nonisolated enum DailyMixRecommendations {
    /// AudioMuse can occasionally return a nearest-neighbour set dominated by
    /// one artist. A Daily Mix should cross at least one artist boundary and
    /// avoid letting any single artist consume most of the visible shelf.
    static func select(from tracks: [Track], limit: Int = 12) -> [Track] {
        guard limit > 0 else { return [] }
        let grouped = Dictionary(grouping: tracks) { artistKey($0.artistName) }
        guard grouped.keys.filter({ !$0.isEmpty }).count >= 2 else { return [] }

        var artistCounts: [String: Int] = [:]
        var selected: [Track] = []
        let perArtistLimit = max(2, limit / 4)

        for track in tracks {
            let key = artistKey(track.artistName)
            if artistCounts[key, default: 0] < perArtistLimit {
                selected.append(track)
                artistCounts[key, default: 0] += 1
            }
            if selected.count == limit { return selected }
        }
        return selected
    }

    private static func artistKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

nonisolated struct DiscoverySnapshot: Codable, Equatable, Sendable {
    let shelves: [DiscoveryShelf]
    let fallbackTracks: [Track]
    let recentTracks: [Track]?
    var rediscoverTracks: [Track]? = nil
    var offTheBeatenPathTracks: [Track]? = nil
    var strategyVersion: Int? = nil
    let recentSignature: [String]
    let refreshedAt: Date
}

private nonisolated enum DailyMixFetchOutcome: Sendable {
    case items([BaseItemDto])
    case failed(String)
    case cancelled
}

private nonisolated struct DailyMixFetchResult: Sendable {
    let seed: DynamicDiscoverySelector.DailyMixSeed
    let outcome: DailyMixFetchOutcome
}

nonisolated enum DynamicDiscoverySelector {
    // 4: eight mixes rather than five. The count is part of the strategy, so
    // stored snapshots built under the old one have to be rebuilt rather than
    // served until the day rolls over.
    static let dailyMixStrategyVersion = 4

    nonisolated struct DailyMixSeed: Equatable, Sendable {
        let track: Track
        let title: String
    }

    static func dailyMixSeeds(
        from candidates: [DiscoveryCandidate],
        recentTrackIDs: Set<String>,
        now: Date,
        limit: Int = 5
    ) -> [DailyMixSeed] {
        guard limit > 0 else { return [] }
        let recentCutoff = now.addingTimeInterval(-14 * 24 * 60 * 60)
        let eligible = candidates.filter {
            !recentTrackIDs.contains($0.track.id)
                && ($0.lastPlayedAt == nil || $0.lastPlayedAt! < recentCutoff)
        }
        let ranked = eligible.sorted {
            if $0.isFavorite != $1.isFavorite { return $0.isFavorite }
            if $0.playCount != $1.playCount { return $0.playCount > $1.playCount }
            return $0.track.id < $1.track.id
        }
        let rotated = stableOrder(
            Array(ranked.prefix(max(limit * 12, limit))),
            period: dayKey(for: now)
        )

        var selected: [DailyMixSeed] = []
        var usedTracks = Set<String>()
        var usedArtists = Set<String>()
        var usedGenres = Set<String>()
        let regionCount = min(3, limit)

        // First cover distinct regions of taste. Genre is preferred, with the
        // artist acting as a useful region when Jellyfin has sparse tagging.
        for candidate in rotated {
            let artist = artistKey(candidate.track)
            let genres = Set(candidate.track.genreIDs ?? [])
            let addsGenre = !genres.isEmpty && genres.isDisjoint(with: usedGenres)
            guard addsGenre || (!usedArtists.contains(artist) && usedGenres.isEmpty) else { continue }
            selected.append(DailyMixSeed(track: candidate.track, title: "\(candidate.track.artistName) Mix"))
            usedTracks.insert(candidate.track.id)
            usedArtists.insert(artist)
            usedGenres.formUnion(genres)
            if selected.count == regionCount { break }
        }

        // Sparse genre metadata should not reduce the number of broad mixes.
        for candidate in rotated where selected.count < regionCount {
            let artist = artistKey(candidate.track)
            guard !usedTracks.contains(candidate.track.id), !usedArtists.contains(artist) else { continue }
            selected.append(DailyMixSeed(track: candidate.track, title: "\(candidate.track.artistName) Mix"))
            usedTracks.insert(candidate.track.id)
            usedArtists.insert(artist)
        }

        // The remaining slots are deliberately song-led. This gives AudioMuse
        // a precise sonic starting point alongside the broader taste regions.
        for candidate in rotated where selected.count < limit {
            let artist = artistKey(candidate.track)
            guard !usedTracks.contains(candidate.track.id), !usedArtists.contains(artist) else { continue }
            selected.append(DailyMixSeed(track: candidate.track, title: "\(candidate.track.name) Mix"))
            usedTracks.insert(candidate.track.id)
            usedArtists.insert(artist)
        }
        return selected
    }

    static func rediscover(
        from candidates: [DiscoveryCandidate],
        now: Date,
        limit: Int = 24
    ) -> [Track] {
        let neglectCutoff = now.addingTimeInterval(-120 * 24 * 60 * 60)
        let eligible = candidates.filter { candidate in
            guard let lastPlayedAt = candidate.lastPlayedAt else { return false }
            return lastPlayedAt < neglectCutoff && (candidate.isFavorite || candidate.playCount >= 2)
        }
        return select(
            eligible.sorted {
                if $0.isFavorite != $1.isFavorite { return $0.isFavorite }
                if $0.playCount != $1.playCount { return $0.playCount > $1.playCount }
                return ($0.lastPlayedAt ?? .distantPast) < ($1.lastPlayedAt ?? .distantPast)
            },
            period: periodKey(for: now, component: .weekOfYear),
            limit: limit
        )
    }

    static func offTheBeatenPath(
        from candidates: [DiscoveryCandidate],
        now: Date,
        limit: Int = 24
    ) -> [Track] {
        let recentCutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
        let eligible = candidates.filter { candidate in
            candidate.playCount <= 1
                && (candidate.lastPlayedAt == nil || candidate.lastPlayedAt! < recentCutoff)
        }
        return select(
            eligible.sorted {
                if ($0.lastPlayedAt == nil) != ($1.lastPlayedAt == nil) {
                    return $0.lastPlayedAt == nil
                }
                if $0.playCount != $1.playCount { return $0.playCount < $1.playCount }
                return $0.track.id < $1.track.id
            },
            period: periodKey(for: now, component: .day),
            limit: limit
        )
    }

    static func dayKey(for date: Date) -> String {
        periodKey(for: date, component: .day)
    }

    private enum PeriodComponent { case day, weekOfYear }

    private static func periodKey(for date: Date, component: PeriodComponent) -> String {
        let calendar = Calendar(identifier: .iso8601)
        let parts: DateComponents
        switch component {
        case .day:
            parts = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        case .weekOfYear:
            parts = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            return String(format: "%04d-W%02d", parts.yearForWeekOfYear ?? 0, parts.weekOfYear ?? 0)
        }
    }

    private static func select(
        _ candidates: [DiscoveryCandidate],
        period: String,
        limit: Int
    ) -> [Track] {
        // Pull from a broad high-quality pool, then use a stable period-based
        // order so the collection changes without jumping around on every visit.
        let pool = Array(candidates.prefix(max(limit * 5, limit)))
            .sorted { stableValue("\(period)|\($0.track.id)") < stableValue("\(period)|\($1.track.id)") }
        var artistCounts: [String: Int] = [:]
        var selected: [Track] = []
        for candidate in pool {
            let artist = candidate.track.artistId
                ?? candidate.track.artistName.lowercased()
            guard artistCounts[artist, default: 0] < 2 else { continue }
            artistCounts[artist, default: 0] += 1
            selected.append(candidate.track)
            if selected.count == limit { break }
        }
        return selected
    }

    private static func stableOrder(
        _ candidates: [DiscoveryCandidate],
        period: String
    ) -> [DiscoveryCandidate] {
        candidates.sorted {
            stableValue("\(period)|\($0.track.id)") < stableValue("\(period)|\($1.track.id)")
        }
    }

    private static func artistKey(_ track: Track) -> String {
        track.artistId ?? track.artistName.lowercased()
    }

    private static func stableValue(_ value: String) -> UInt64 {
        value.utf8.reduce(14_695_981_039_346_656_037) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }
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
    private static let recentTrackWindow = 100
    private static let maximumRecentItemCount = 12
    static let maximumMixShelfCount = 8

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Aurelia",
        category: "Discovery"
    )

    @Published private(set) var shelves: [DiscoveryShelf] = []
    @Published private(set) var fallbackTracks: [Track] = []
    @Published private(set) var recentTracks: [Track] = []
    @Published private(set) var rediscoverTracks: [Track] = []
    @Published private(set) var offTheBeatenPathTracks: [Track] = []
    @Published private(set) var availability: AudioMuseAvailability = .checking
    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshing = false
    @Published var errorMessage: String?
    @Published private(set) var errorDetails: String?

    private let api: any DiscoveryAPI
    private let recentTracksProvider: () -> [Track]
    private let recentCache: (any RecentTrackCaching)?
    private let recentScope: LibraryScope?
    private let cache: DiscoveryCache?
    private let snapshotRepository: LibraryRepository?
    private let snapshotScope: LibraryScope?
    private let candidateProvider: (any DiscoveryCandidateProviding)?
    private let now: () -> Date
    private var hasLoadedDatabaseCache = false
    private var loadedRecentSignature: [String] = []
    private var lastRefreshDate: Date?
    private var pendingSnapshot: DiscoverySnapshot?
    private var isPreparingRefresh = false
    private var refreshGeneration: UInt64 = 0
    private var observedActiveAnalysis = false
    private var hasConfirmedAudioMusePresence = false
    private var hasGeneratedDynamicContent = false
    private var loadedStrategyVersion: Int?

    convenience init() {
        let service = JellyfinService.shared
        self.init(
            api: service,
            recentTracksProvider: { PlayerManager.shared.recentlyPlayedTracks },
            recentCache: LibraryRepository.shared,
            recentScope: service.libraryScope,
            snapshotRepository: LibraryRepository.shared,
            snapshotScope: service.libraryScope,
            candidateProvider: LibraryRepository.shared,
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
        candidateProvider: (any DiscoveryCandidateProviding)? = nil,
        now: @escaping () -> Date = Date.init,
        cache: DiscoveryCache? = nil
    ) {
        self.api = api
        self.recentTracksProvider = recentTracksProvider
        self.recentCache = recentCache
        self.recentScope = recentScope
        self.snapshotRepository = snapshotRepository
        self.snapshotScope = snapshotScope
        self.candidateProvider = candidateProvider
        self.now = now
        self.cache = cache
        recentTracks = Self.uniqueRecentTracks(recentTracksProvider())

        if let snapshot = cache?.load() {
            shelves = snapshot.shelves
            recentTracks = snapshot.recentTracks ?? recentTracks
            rediscoverTracks = snapshot.rediscoverTracks ?? []
            offTheBeatenPathTracks = snapshot.offTheBeatenPathTracks ?? []
            hasGeneratedDynamicContent = snapshot.rediscoverTracks != nil
                || snapshot.offTheBeatenPathTracks != nil
            loadedStrategyVersion = snapshot.strategyVersion
            fallbackTracks = recentTracks.isEmpty ? snapshot.fallbackTracks : []
            loadedRecentSignature = snapshot.recentSignature
            lastRefreshDate = snapshot.refreshedAt
        }
    }

    var hasContent: Bool {
        !shelves.isEmpty || !rediscoverTracks.isEmpty || !offTheBeatenPathTracks.isEmpty
            || !fallbackTracks.isEmpty || !recentTracks.isEmpty
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
        let freshestRefreshDate = pendingSnapshot?.refreshedAt ?? lastRefreshDate
        let dynamicContentMissing = !hasGeneratedDynamicContent && candidateProvider != nil
        let strategyChanged = loadedStrategyVersion != DynamicDiscoverySelector.dailyMixStrategyVersion
        let dayChanged = freshestRefreshDate.map {
            DynamicDiscoverySelector.dayKey(for: $0) != DynamicDiscoverySelector.dayKey(for: now())
        } ?? true
        guard !hasContent || dynamicContentMissing || strategyChanged || dayChanged else { return }
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
            let fetchedRecentTracks = try await fetchRecentlyPlayedTracks()
            // A full library sync and this lightweight refresh can overlap.
            // Some Jellyfin versions briefly return only the currently playing
            // item while their user-data index is being rebuilt. Put fresh
            // results first, but never let that transient partial window erase
            // the last known-good Recently Played shelf.
            let recentTracks = Self.mergingRecentTracks(
                fresh: fetchedRecentTracks,
                retained: self.recentTracks,
                limit: Self.recentTrackWindow
            )
            let discoveryCandidates: [DiscoveryCandidate]
            if let candidateProvider, let snapshotScope {
                discoveryCandidates = await candidateProvider.discoveryCandidates(in: snapshotScope)
            } else {
                discoveryCandidates = []
            }
            let rediscoverTracks = DynamicDiscoverySelector.rediscover(
                from: discoveryCandidates,
                now: now()
            )
            let offTheBeatenPathTracks = DynamicDiscoverySelector.offTheBeatenPath(
                from: discoveryCandidates,
                now: now()
            )
            let audioMuseAvailable = await audioMuseIsAvailable()
            let recentCutoff = now().addingTimeInterval(-14 * 24 * 60 * 60)
            let recentTrackIDs = Set(recentTracks.map(\.id)).union(
                discoveryCandidates.compactMap { candidate in
                    guard let lastPlayedAt = candidate.lastPlayedAt,
                          lastPlayedAt >= recentCutoff else { return nil }
                    return candidate.track.id
                }
            )
            let dailySeeds = audioMuseAvailable
                ? DynamicDiscoverySelector.dailyMixSeeds(
                    from: discoveryCandidates,
                    recentTrackIDs: recentTrackIDs,
                    now: now(),
                    limit: Self.maximumMixShelfCount
                )
                : []

            var newShelves: [DiscoveryShelf] = []
            var usedRecommendationIds = Set<String>()
            var mixFailures: [String] = []
            var emptyMixCount = 0

            // AudioMuse requests can be computationally expensive. Run two at
            // a time: enough to prevent sequential timeouts from stacking up,
            // without stampeding the plugin with every seed simultaneously.
            var mixResults: [DailyMixFetchResult] = []
            var seedIndex = 0
            while seedIndex < dailySeeds.count {
                let firstSeed = dailySeeds[seedIndex]
                if seedIndex + 1 < dailySeeds.count {
                    let secondSeed = dailySeeds[seedIndex + 1]
                    async let first = fetchDailyMix(for: firstSeed)
                    async let second = fetchDailyMix(for: secondSeed)
                    let pair = await (first, second)
                    mixResults.append(contentsOf: [pair.0, pair.1])
                } else {
                    mixResults.append(await fetchDailyMix(for: firstSeed))
                }
                seedIndex += 2
            }

            for result in mixResults where newShelves.count < Self.maximumMixShelfCount {
                let dailySeed = result.seed
                let seed = dailySeed.track
                switch result.outcome {
                case .items(let items):
                    let tracks = items
                        .filter { $0.Type == .Audio && $0.Id != seed.id }
                        .map { Track(from: $0, baseURL: api.baseURL) }
                        .filter { !recentTrackIDs.contains($0.id) }
                        .filter { !usedRecommendationIds.contains($0.id) }
                    let recommendations = DailyMixRecommendations.select(from: tracks)
                    if !recommendations.isEmpty {
                        usedRecommendationIds.formUnion(recommendations.map(\.id))
                        newShelves.append(DiscoveryShelf(seed: seed, tracks: recommendations, title: dailySeed.title))
                    } else {
                        emptyMixCount += 1
                        Self.logger.info(
                            "Instant Mix returned no recommendations for seed \(seed.id, privacy: .private(mask: .hash))"
                        )
                    }
                case .cancelled:
                    throw CancellationError()
                case .failed(let message):
                    mixFailures.append("\(dailySeed.title): \(message)")
                    Self.logger.warning(
                        "Instant Mix failed for seed \(seed.id, privacy: .private(mask: .hash)): \(message, privacy: .public)"
                    )
                }
            }

            guard !newShelves.isEmpty || !discoveryCandidates.isEmpty || !recentTracks.isEmpty else {
                throw DiscoveryError.noMusic
            }

            // A refresh is transactional for recommendation shelves. Recent
            // playback can still move forward, but a temporary plugin/server
            // failure must never replace known-good mixes with an empty array.
            // A refresh is only allowed to improve known-good recommendations.
            // Plugin health and analysis state are transient, so neither may
            // erase shelves that were generated successfully earlier.
            let reusablePreviousShelves = previousShelves.filter {
                !DailyMixRecommendations.select(from: $0.tracks).isEmpty
            }
            let generatedSeedIDs = Set(newShelves.map(\.seed.id))
            let resolvedShelves = MixShelfOrdering.artworkFirst(
                Array((newShelves + reusablePreviousShelves.filter {
                    !generatedSeedIDs.contains($0.seed.id)
                }).prefix(Self.maximumMixShelfCount))
            )
            let resolvedRediscoverTracks = discoveryCandidates.isEmpty
                ? self.rediscoverTracks
                : rediscoverTracks
            let resolvedOffTheBeatenPathTracks = discoveryCandidates.isEmpty
                ? self.offTheBeatenPathTracks
                : offTheBeatenPathTracks
            let fallbackTracks = resolvedShelves.isEmpty && recentTracks.isEmpty
                ? Array(discoveryCandidates.map(\.track).prefix(12))
                : []
            let visibleRecentTracks = RecentPlayGrouping.tracksForVisibleItems(
                recentTracks,
                limit: Self.maximumRecentItemCount
            )
            let snapshot = DiscoverySnapshot(
                shelves: resolvedShelves,
                fallbackTracks: fallbackTracks,
                recentTracks: visibleRecentTracks,
                rediscoverTracks: resolvedRediscoverTracks,
                offTheBeatenPathTracks: resolvedOffTheBeatenPathTracks,
                strategyVersion: DynamicDiscoverySelector.dailyMixStrategyVersion,
                recentSignature: visibleRecentTracks.map(\.id),
                refreshedAt: now()
            )
            let mixIssue = mixRefreshIssue(
                candidatesWereAvailable: !dailySeeds.isEmpty,
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
                errorDetails = mixIssue == nil ? nil : mixRefreshDetails(
                    failureDescriptions: mixFailures,
                    emptyMixCount: emptyMixCount
                )
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
                errorDetails = String(describing: error)
            }
        }
    }

    private func fetchDailyMix(
        for seed: DynamicDiscoverySelector.DailyMixSeed
    ) async -> DailyMixFetchResult {
        do {
            try Task.checkCancellation()
            let items = try await api.fetchInstantMix(itemId: seed.track.id, limit: 40)
            try Task.checkCancellation()
            return DailyMixFetchResult(seed: seed, outcome: .items(items))
        } catch is CancellationError {
            return DailyMixFetchResult(seed: seed, outcome: .cancelled)
        } catch {
            return DailyMixFetchResult(seed: seed, outcome: .failed(error.localizedDescription))
        }
    }

    func updateAudioMuseStatus() async {
        let previous = availability
        let reading = await AudioMuseStatusProbe.read(
            from: api,
            presenceAlreadyConfirmed: hasConfirmedAudioMusePresence
        )
        hasConfirmedAudioMusePresence = reading.confirmedPresence
        // Nil means the request was cancelled, so nothing was learned.
        guard let resolved = reading.availability else { return }
        availability = resolved

        if case .analyzing = resolved {
            observedActiveAnalysis = true
        } else if observedActiveAnalysis, case .analyzing = previous {
            // An analysis that has just finished leaves better recommendations
            // behind it, so the shelves are worth rebuilding once.
            observedActiveAnalysis = false
            await refresh(force: true, publishResult: false)
        }
    }

    /// Plugin presence is the only capability gate. Health and analysis are
    /// status signals — AudioMuse can still serve its last completed model.
    private func audioMuseIsAvailable() async -> Bool {
        let reading = await AudioMuseStatusProbe.read(
            from: api,
            presenceAlreadyConfirmed: hasConfirmedAudioMusePresence
        )
        hasConfirmedAudioMusePresence = reading.confirmedPresence
        if let resolved = reading.availability {
            availability = resolved
            if case .analyzing = resolved { observedActiveAnalysis = true }
        }
        return reading.confirmedPresence
    }

    private static func uniqueRecentTracks(_ tracks: [Track]) -> [Track] {
        var itemIds = Set<String>()
        return tracks.filter { itemIds.insert($0.id).inserted }
    }

    static func mergingRecentTracks(
        fresh: [Track],
        retained: [Track],
        limit: Int
    ) -> [Track] {
        Array(uniqueRecentTracks(fresh + retained).prefix(limit))
    }

    private func fetchRecentlyPlayedTracks() async throws -> [Track] {
        do {
            let items = try await api.fetchRecentlyPlayedTracks(limit: Self.recentTrackWindow)
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
                    await recentCache.cachedRecentTracks(in: recentScope, limit: Self.recentTrackWindow)
                )
            }
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
            ? "Couldn’t refresh Daily Mixes. Showing the previous mixes."
            : "Daily Mixes are temporarily unavailable."
        return summary
    }

    private func mixRefreshDetails(
        failureDescriptions: [String],
        emptyMixCount: Int
    ) -> String {
        var lines = failureDescriptions
        if emptyMixCount > 0 {
            let noun = emptyMixCount == 1 ? "mix" : "mixes"
            lines.append("\(emptyMixCount) \(noun) returned no usable recommendations.")
        }
        return lines.joined(separator: "\n")
    }

    private func applyPendingSnapshot() {
        guard let pendingSnapshot else { return }
        apply(pendingSnapshot)
        self.pendingSnapshot = nil
        errorMessage = nil
        errorDetails = nil
    }

    private func apply(_ snapshot: DiscoverySnapshot) {
        shelves = snapshot.shelves
        recentTracks = snapshot.recentTracks ?? recentTracks
        rediscoverTracks = snapshot.rediscoverTracks ?? []
        offTheBeatenPathTracks = snapshot.offTheBeatenPathTracks ?? []
        hasGeneratedDynamicContent = snapshot.rediscoverTracks != nil
            || snapshot.offTheBeatenPathTracks != nil
        loadedStrategyVersion = snapshot.strategyVersion
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
