//
//  FavoritesOfflineSync.swift
//  Aurelia
//
//  Keeps the favorites the user has chosen available without a server.
//
//  Downloading everything liked *once* goes stale the moment it finishes — the
//  track hearted yesterday is not on the plane today — so this is a standing
//  rule rather than an action. It watches the same two signals the favorites
//  screen trusts (a local like, and a library sync landing) and reconciles what
//  is on disk against what the rule says should be there.
//

import Combine
import Foundation
import UserNotifications

// MARK: - Settings

nonisolated enum FavoritesOfflineDefaults {
    static let isEnabled = "favoritesOfflineEnabled"
    static let includesTracks = "favoritesOfflineIncludesTracks"
    static let includesAlbums = "favoritesOfflineIncludesAlbums"
    static let includesArtists = "favoritesOfflineIncludesArtists"
    static let allowsCellular = "favoritesOfflineAllowsCellular"

    /// Two of these default to on, which `UserDefaults.bool(forKey:)` cannot
    /// express on its own. Registering them keeps every reader — this service,
    /// `DownloadManager`, and any `@AppStorage` binding — on the same answer.
    static func register(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            includesTracks: true,
            includesAlbums: true,
            includesArtists: false,
            allowsCellular: false
        ])
    }
}

/// Which kinds of favorite the rule covers.
nonisolated struct FavoritesOfflineScope: Equatable, Sendable {
    var includesTracks = true
    var includesAlbums = true
    /// Off by default: one liked artist can mean a forty-album discography,
    /// which is not something a toggle should quietly commit tens of GB to.
    var includesArtists = false

    var isEmpty: Bool { !includesTracks && !includesAlbums && !includesArtists }
}

// MARK: - Pure reconciliation

/// The work needed to bring the device in line with the rule.
nonisolated struct FavoritesOfflinePlan: Equatable, Sendable {
    /// Not on the device and not already queued for the rule.
    var toDownload: [Track] = []
    /// Already on the device for some other reason; the rule now wants it too.
    var toAdopt: [String] = []
    /// The rule wanted these once and does not any more.
    var toRelease: [String] = []

    var isEmpty: Bool { toDownload.isEmpty && toAdopt.isEmpty && toRelease.isEmpty }
}

/// The decision-making half of the feature, with no dependencies on downloads,
/// the network, or the database — everything here is a function of its inputs.
nonisolated enum FavoritesOfflineReconciler {
    /// Everything the scope says should exist offline, deduplicated.
    ///
    /// A track can arrive from all three directions at once — liked itself, on
    /// a liked album, by a liked artist — and it is still one file.
    static func desiredTracks(
        favoriteTracks: [Track],
        likedAlbumTracks: [Track],
        likedArtistTracks: [Track],
        scope: FavoritesOfflineScope
    ) -> [Track] {
        var seen: Set<String> = []
        var result: [Track] = []

        func absorb(_ tracks: [Track]) {
            for track in tracks where seen.insert(track.id).inserted {
                result.append(track)
            }
        }

        if scope.includesTracks { absorb(favoriteTracks) }
        if scope.includesAlbums { absorb(likedAlbumTracks) }
        if scope.includesArtists { absorb(likedArtistTracks) }

        return result
    }

    /// Diffs the desired set against what the device has.
    ///
    /// - Parameter ruleOwnedPending: tracks the rule has already asked for that
    ///   have not produced a file yet. Excluding them is what makes a second
    ///   pass over an unchanged library do nothing.
    static func plan(
        desired: [Track],
        downloaded: [DownloadedTrack],
        ruleOwnedPending: Set<String>
    ) -> FavoritesOfflinePlan {
        let desiredIDs = Set(desired.map(\.id))
        var downloadedByID: [String: DownloadedTrack] = [:]
        downloadedByID.reserveCapacity(downloaded.count)
        for track in downloaded {
            downloadedByID[track.trackId] = track
        }

        var plan = FavoritesOfflinePlan()

        for track in desired {
            guard let existing = downloadedByID[track.id] else {
                if !ruleOwnedPending.contains(track.id) {
                    plan.toDownload.append(track)
                }
                continue
            }
            if !existing.owners.contains(.favoritesRule) {
                plan.toAdopt.append(track.id)
            }
        }

        for track in downloaded
        where track.owners.contains(.favoritesRule) && !desiredIDs.contains(track.trackId) {
            plan.toRelease.append(track.trackId)
        }
        for trackID in ruleOwnedPending.sorted() where !desiredIDs.contains(trackID) {
            plan.toRelease.append(trackID)
        }

        return plan
    }
}

// MARK: - Reporting

/// What one scope would cost, for the confirmation sheet.
nonisolated struct FavoritesOfflineScopePreview: Equatable, Sendable, Identifiable {
    enum Kind: String, Sendable {
        case tracks, albums, artists
    }

    let kind: Kind
    /// Liked tracks / liked albums / liked artists.
    let itemCount: Int
    let trackCount: Int
    let duration: TimeInterval

    var id: String { kind.rawValue }
}

nonisolated struct FavoritesOfflineEstimate: Equatable, Sendable {
    let desiredTrackCount: Int
    let missingTrackCount: Int
    let missingBytes: Int64
    let freeBytes: Int64

    /// Leaves the device a tenth of its free space rather than filling it.
    var fitsOnDevice: Bool {
        missingBytes < Int64(Double(freeBytes) * 0.9)
    }
}

// MARK: - Service

@MainActor
final class FavoritesOfflineSync: ObservableObject {
    static let shared = FavoritesOfflineSync()

    enum Status: Equatable {
        /// The rule is off.
        case off
        /// On, but there is no library to read favorites from yet.
        case unavailable
        case upToDate(trackCount: Int)
        case syncing(completed: Int, total: Int)
        case waitingForWiFi(remaining: Int)
        case paused(completed: Int, total: Int)
        case failed(completed: Int, total: Int, failures: Int)
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var desiredTrackIDs: Set<String> = []
    @Published private(set) var estimate: FavoritesOfflineEstimate?
    @Published private(set) var previews: [FavoritesOfflineScopePreview] = []
    @Published private(set) var isReconciling = false

    @Published var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            defaults.set(isEnabled, forKey: FavoritesOfflineDefaults.isEnabled)
            if isEnabled {
                scheduleReconcile(after: 0)
            } else {
                refreshStatus()
            }
        }
    }

    @Published var scope: FavoritesOfflineScope {
        didSet {
            guard oldValue != scope else { return }
            defaults.set(scope.includesTracks, forKey: FavoritesOfflineDefaults.includesTracks)
            defaults.set(scope.includesAlbums, forKey: FavoritesOfflineDefaults.includesAlbums)
            defaults.set(scope.includesArtists, forKey: FavoritesOfflineDefaults.includesArtists)
            if isEnabled { scheduleReconcile(after: 0) }
        }
    }

    @Published var allowsCellular: Bool {
        didSet {
            guard oldValue != allowsCellular else { return }
            defaults.set(allowsCellular, forKey: FavoritesOfflineDefaults.allowsCellular)
            downloadManager.networkPolicyDidChange()
        }
    }

    private let defaults: UserDefaults
    private let downloadManager: DownloadManager
    private var cancellables: Set<AnyCancellable> = []
    private var reconcileTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var isStarted = false
    /// Set while a run has outstanding work, so the summary notification fires
    /// once on the way to done rather than every time the count is recomputed.
    private var hasUnreportedWork = false

    /// Favorites that produced the current desired set. Recomputing the set
    /// means walking every liked album and artist in SQLite, which is not worth
    /// doing when a like landed on something outside the scope.
    private var lastFavoritesFingerprint: String?
    private var cachedDesired: [Track] = []

    init(defaults: UserDefaults = .standard, downloadManager: DownloadManager = .shared) {
        FavoritesOfflineDefaults.register(in: defaults)
        self.defaults = defaults
        self.downloadManager = downloadManager
        self.isEnabled = defaults.bool(forKey: FavoritesOfflineDefaults.isEnabled)
        self.scope = FavoritesOfflineScope(
            includesTracks: defaults.bool(forKey: FavoritesOfflineDefaults.includesTracks),
            includesAlbums: defaults.bool(forKey: FavoritesOfflineDefaults.includesAlbums),
            includesArtists: defaults.bool(forKey: FavoritesOfflineDefaults.includesArtists)
        )
        self.allowsCellular = defaults.bool(forKey: FavoritesOfflineDefaults.allowsCellular)
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        FavoriteMutationCenter.shared.$latestEvent
            .compactMap { $0 }
            .sink { [weak self] _ in
                self?.scheduleReconcile()
            }
            .store(in: &cancellables)

        LibraryStore.shared.$catalogRevision
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                self?.scheduleReconcile()
            }
            .store(in: &cancellables)

        // Progress and failures live on the download manager; the rule only
        // knows which tracks it asked for.
        downloadManager.objectWillChange
            .throttle(for: .milliseconds(500), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                self?.refreshStatus()
            }
            .store(in: &cancellables)

        if isEnabled {
            scheduleReconcile(after: 0)
        }
    }

    /// Called on the way back to the foreground, where the mutation and sync
    /// signals that fired while the app was suspended were never delivered.
    func refresh() {
        guard isEnabled else { return }
        scheduleReconcile()
    }

    // MARK: - Enabling and disabling

    /// Turns the rule off. Files the rule is holding either become ordinary
    /// downloads or go — the user is asked which, because deleting music
    /// somebody may be about to fly with is not a default.
    func disable(removingDownloads: Bool) {
        isEnabled = false
        debounceTask?.cancel()
        reconcileTask?.cancel()
        desiredTrackIDs = []
        cachedDesired = []
        lastFavoritesFingerprint = nil
        hasUnreportedWork = false

        downloadManager.cancelDownloads(for: .favoritesRule)

        let ruleOwned = downloadManager.downloadedTracks
            .filter { $0.owners.contains(.favoritesRule) }
            .map(\.trackId)

        for trackID in ruleOwned {
            if !removingDownloads {
                // Hand the file to the user before the rule lets go of it, so
                // "keep" cannot race with the last-owner deletion.
                downloadManager.adopt(trackID: trackID, by: .manual)
            }
            downloadManager.relinquish(trackID: trackID, by: .favoritesRule)
        }

        refreshStatus()
    }

    // MARK: - Reconciling

    private func scheduleReconcile(after delay: TimeInterval = 2.0) {
        guard isEnabled else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
            }
            await self?.reconcile()
        }
    }

    /// Brings the device in line with the rule. Safe to call as often as the
    /// triggers fire: an unchanged library produces an empty plan.
    func reconcile() async {
        guard isEnabled else { return }
        guard let libraryScope = JellyfinService.shared.libraryScope else {
            status = .unavailable
            return
        }

        reconcileTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performReconcile(in: libraryScope)
        }
        reconcileTask = task
        await task.value
    }

    private func performReconcile(in libraryScope: LibraryScope) async {
        isReconciling = true
        defer { isReconciling = false }

        let snapshot = await LibraryRepository.shared.favoriteSnapshot(in: libraryScope)
        let fingerprint = Self.fingerprint(of: snapshot, scope: scope)

        let desired: [Track]
        if fingerprint == lastFavoritesFingerprint, !cachedDesired.isEmpty {
            // Nothing feeding the desired set changed. Skip walking every liked
            // album and artist in SQLite and go straight to diffing against
            // what is on disk, which may still have moved underneath us.
            desired = cachedDesired
        } else {
            desired = await resolveDesired(snapshot: snapshot, in: libraryScope)
            guard !Task.isCancelled else { return }
            cachedDesired = desired
            lastFavoritesFingerprint = fingerprint
        }

        guard !Task.isCancelled else { return }

        desiredTrackIDs = Set(desired.map(\.id))

        let plan = FavoritesOfflineReconciler.plan(
            desired: desired,
            downloaded: downloadManager.downloadedTracks,
            ruleOwnedPending: ruleOwnedPendingIDs()
        )

        // The rule can be switched off while the database reads above are in
        // flight, and acting on this plan would undo the teardown.
        guard isEnabled else { return }
        apply(plan)
        updateEstimate(desired: desired)
        refreshStatus()
    }

    private func resolveDesired(
        snapshot: FavoritesSnapshot,
        in libraryScope: LibraryScope
    ) async -> [Track] {
        let repository = LibraryRepository.shared

        var albumTracks: [Track] = []
        if scope.includesAlbums {
            for album in snapshot.albums {
                guard !Task.isCancelled else { return [] }
                albumTracks += (try? await repository.tracks(inAlbum: album.id, in: libraryScope)) ?? []
            }
        }

        var artistTracks: [Track] = []
        if scope.includesArtists {
            for artist in snapshot.artists {
                guard !Task.isCancelled else { return [] }
                artistTracks += (try? await repository.tracks(forArtist: artist.id, in: libraryScope)) ?? []
            }
        }

        return FavoritesOfflineReconciler.desiredTracks(
            favoriteTracks: snapshot.tracks,
            likedAlbumTracks: albumTracks,
            likedArtistTracks: artistTracks,
            scope: scope
        )
    }

    private func apply(_ plan: FavoritesOfflinePlan) {
        for trackID in plan.toRelease {
            downloadManager.relinquish(trackID: trackID, by: .favoritesRule)
        }
        for trackID in plan.toAdopt {
            downloadManager.adopt(trackID: trackID, by: .favoritesRule)
        }
        if !plan.toDownload.isEmpty {
            hasUnreportedWork = true
            downloadManager.enqueue(plan.toDownload, origin: .favoritesRule)
        }
    }

    private func ruleOwnedPendingIDs() -> Set<String> {
        Set(
            downloadManager.pendingTrackIDs(ownedBy: .favoritesRule)
        )
    }

    // MARK: - Preview and estimate

    /// Walks every scope, including the ones that are switched off, so the
    /// confirmation sheet can put a number next to each row before the user
    /// commits to it.
    func loadPreviews() async {
        guard let libraryScope = JellyfinService.shared.libraryScope else {
            previews = []
            return
        }

        let repository = LibraryRepository.shared
        let snapshot = await LibraryRepository.shared.favoriteSnapshot(in: libraryScope)

        var albumTracks: [Track] = []
        for album in snapshot.albums {
            albumTracks += (try? await repository.tracks(inAlbum: album.id, in: libraryScope)) ?? []
        }

        var artistTracks: [Track] = []
        for artist in snapshot.artists {
            artistTracks += (try? await repository.tracks(forArtist: artist.id, in: libraryScope)) ?? []
        }

        guard !Task.isCancelled else { return }

        previews = [
            FavoritesOfflineScopePreview(
                kind: .tracks,
                itemCount: snapshot.tracks.count,
                trackCount: snapshot.tracks.count,
                duration: snapshot.tracks.reduce(0) { $0 + $1.duration }
            ),
            FavoritesOfflineScopePreview(
                kind: .albums,
                itemCount: snapshot.albums.count,
                trackCount: albumTracks.count,
                duration: albumTracks.reduce(0) { $0 + $1.duration }
            ),
            FavoritesOfflineScopePreview(
                kind: .artists,
                itemCount: snapshot.artists.count,
                trackCount: artistTracks.count,
                duration: artistTracks.reduce(0) { $0 + $1.duration }
            )
        ]
    }

    /// Bytes per second of audio, measured from files already on the device.
    var bytesPerSecond: Double { downloadManager.observedBytesPerSecond }

    func estimatedBytes(forDuration duration: TimeInterval) -> Int64 {
        Int64(duration * bytesPerSecond)
    }

    private func updateEstimate(desired: [Track]) {
        let missing = desired.filter { !downloadManager.isDownloaded(trackId: $0.id) }
        let missingDuration = missing.reduce(0.0) { $0 + $1.duration }

        estimate = FavoritesOfflineEstimate(
            desiredTrackCount: desired.count,
            missingTrackCount: missing.count,
            missingBytes: estimatedBytes(forDuration: missingDuration),
            freeBytes: Self.freeDiskBytes()
        )
    }

    static func freeDiskBytes() -> Int64 {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    // MARK: - Status

    private func refreshStatus() {
        guard isEnabled else {
            status = .off
            return
        }
        guard JellyfinService.shared.libraryScope != nil else {
            status = .unavailable
            return
        }

        let total = desiredTrackIDs.count
        guard total > 0 else {
            // The first pass has not resolved the desired set yet. Reporting
            // "nothing to download" here would be a lie that corrects itself a
            // second later, which reads as a glitch.
            guard !isReconciling else { return }
            status = .upToDate(trackCount: 0)
            return
        }

        var completed = 0
        var failures = 0
        for trackID in desiredTrackIDs {
            if downloadManager.isDownloaded(trackId: trackID) {
                completed += 1
            } else if downloadManager.failedDownloads[trackID] != nil {
                failures += 1
            }
        }

        if completed + failures >= total {
            if failures > 0 {
                status = .failed(completed: completed, total: total, failures: failures)
            } else {
                status = .upToDate(trackCount: total)
            }
            reportCompletionIfNeeded(completed: completed, failures: failures)
            return
        }

        if downloadManager.isPaused {
            status = .paused(completed: completed, total: total)
        } else if downloadManager.isWaitingForWiFi {
            status = .waitingForWiFi(remaining: total - completed - failures)
        } else {
            status = .syncing(completed: completed, total: total)
        }
    }

    /// One notification for a whole run. The per-album alert is suppressed for
    /// rule downloads precisely so this can be the only thing the user sees.
    private func reportCompletionIfNeeded(completed: Int, failures: Int) {
        guard hasUnreportedWork else { return }
        hasUnreportedWork = false

        let content = UNMutableNotificationContent()
        content.title = failures > 0 ? "Favorites Partly Offline" : "Favorites Are Offline"
        let tracks = "\(completed) \(completed == 1 ? "track" : "tracks")"
        content.body = failures > 0
            ? "\(tracks) downloaded · \(failures) failed"
            : "\(tracks) · \(downloadManager.formatBytes(downloadManager.totalStorageUsed))"
        content.sound = .default
        content.categoryIdentifier = "DOWNLOAD_COMPLETE"

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }

    private static func fingerprint(of snapshot: FavoritesSnapshot, scope: FavoritesOfflineScope) -> String {
        var parts: [String] = []
        if scope.includesTracks { parts.append("t:" + snapshot.tracks.map(\.id).sorted().joined(separator: ",")) }
        if scope.includesAlbums { parts.append("l:" + snapshot.albums.map(\.id).sorted().joined(separator: ",")) }
        if scope.includesArtists { parts.append("a:" + snapshot.artists.map(\.id).sorted().joined(separator: ",")) }
        return parts.joined(separator: "|")
    }
}
