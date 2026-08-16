//
//  FavoritesOfflineTests.swift
//  AureliaTests
//
//  Covers the decision-making half of "Keep Favorites Offline" and the
//  persistence it depends on. The reconciler is a pure function of its inputs
//  precisely so it can be tested without a server, a network, or a download.
//

import Testing
import Foundation
import GRDB
@testable import Aurelia

struct FavoritesOfflineTests {

    @Test func aTruncatedTranscodeIsNotMistakenForAFinishedOne() {
        // Jellyfin streams a transcode with no length the client can check, so
        // a server that stops early looks exactly like a download that finished.
        let fourMinutes: TimeInterval = 240
        let whole: Int64 = Int64(fourMinutes * 320_000 / 8)

        #expect(DownloadManager.isPlausiblySized(bytes: whole, duration: fourMinutes, quality: .high))
        #expect(!DownloadManager.isPlausiblySized(bytes: 0, duration: fourMinutes, quality: .high))
        #expect(!DownloadManager.isPlausiblySized(bytes: 40_000, duration: fourMinutes, quality: .high))

        // Encoders undershoot the ceiling they are given — the observed files
        // came back at 256kbps against a 320 request — so the bar sits low
        // enough that an honest file is never thrown away.
        let atMeasuredRate = Int64(fourMinutes * 256_000 / 8)
        #expect(DownloadManager.isPlausiblySized(bytes: atMeasuredRate, duration: fourMinutes, quality: .high))
    }

    @Test func anOriginalFileIsOnlyCheckedForBeingNearlyEmpty() {
        // An original can be a small MP3 or a large FLAC, so there is no rate to
        // hold it to; only something close to empty is a real signal.
        let fourMinutes: TimeInterval = 240

        #expect(DownloadManager.isPlausiblySized(bytes: 5_000_000, duration: fourMinutes, quality: .original))
        #expect(DownloadManager.isPlausiblySized(bytes: 3_000_000, duration: fourMinutes, quality: .original))
        #expect(!DownloadManager.isPlausiblySized(bytes: 1_000, duration: fourMinutes, quality: .original))

        // A jingle is too short to judge by rate at all.
        #expect(DownloadManager.isPlausiblySized(bytes: 4_000, duration: 5, quality: .high))
    }


    // MARK: - Fixtures

    private static func track(_ id: String, album: String = "album", duration: TimeInterval = 200) -> Track {
        Track(
            id: id,
            name: "Track \(id)",
            artistName: "Artist",
            albumName: "Album",
            duration: duration,
            artworkURL: nil,
            albumId: album
        )
    }

    private static func downloaded(
        _ id: String,
        owners: Set<DownloadOrigin>,
        album: String = "album",
        fileSize: Int64 = 1_000_000,
        duration: TimeInterval? = 200,
        quality: DownloadQuality = .original
    ) -> DownloadedTrack {
        DownloadedTrack(
            trackId: id,
            fileName: "\(id).m4a",
            fileSize: fileSize,
            downloadDate: Date(timeIntervalSince1970: 0),
            trackName: "Track \(id)",
            artistName: "Artist",
            albumName: "Album",
            duration: duration,
            albumId: album,
            trackNumber: 1,
            discNumber: 1,
            artistId: "artist",
            productionYear: 2026,
            artworkURL: nil,
            owners: owners,
            quality: quality
        )
    }

    // MARK: - Desired set

    @Test func desiredSetUnionsScopesAndCountsEachTrackOnce() {
        let liked = Self.track("a")
        let onLikedAlbum = Self.track("b")
        let byLikedArtist = Self.track("c")

        let desired = FavoritesOfflineReconciler.desiredTracks(
            // The same track can arrive from all three directions at once.
            favoriteTracks: [liked, onLikedAlbum],
            likedAlbumTracks: [onLikedAlbum, byLikedArtist],
            likedArtistTracks: [byLikedArtist, liked],
            scope: FavoritesOfflineScope(includesTracks: true, includesAlbums: true, includesArtists: true)
        )

        #expect(desired.map(\.id) == ["a", "b", "c"])
    }

    @Test func desiredSetHonoursDisabledScopes() {
        let scope = FavoritesOfflineScope(includesTracks: true, includesAlbums: false, includesArtists: false)

        let desired = FavoritesOfflineReconciler.desiredTracks(
            favoriteTracks: [Self.track("a")],
            likedAlbumTracks: [Self.track("b")],
            likedArtistTracks: [Self.track("c")],
            scope: scope
        )

        #expect(desired.map(\.id) == ["a"])
    }

    @Test func artistsAreOffByDefaultBecauseADiscographyIsUnbounded() {
        let scope = FavoritesOfflineScope()
        #expect(scope.includesTracks)
        #expect(scope.includesAlbums)
        #expect(!scope.includesArtists)
    }

    // MARK: - Planning

    @Test func planDownloadsWhatIsMissingAndAdoptsWhatIsAlreadyThere() {
        let plan = FavoritesOfflineReconciler.plan(
            desired: [Self.track("new"), Self.track("owned-by-hand")],
            downloaded: [Self.downloaded("owned-by-hand", owners: [.manual])],
            ruleOwnedPending: []
        )

        #expect(plan.toDownload.map(\.id) == ["new"])
        // Already on disk for another reason: record the claim, do not refetch.
        #expect(plan.toAdopt == ["owned-by-hand"])
        #expect(plan.toRelease.isEmpty)
    }

    @Test func planReleasesOnlyWhatTheRuleItselfIsHolding() {
        let plan = FavoritesOfflineReconciler.plan(
            desired: [],
            downloaded: [
                Self.downloaded("rule", owners: [.favoritesRule]),
                Self.downloaded("hand-picked", owners: [.manual]),
                Self.downloaded("both", owners: [.manual, .favoritesRule])
            ],
            ruleOwnedPending: []
        )

        // "both" is released by the rule but the file survives — that is the
        // download manager's call, not the plan's.
        #expect(Set(plan.toRelease) == ["rule", "both"])
        #expect(!plan.toRelease.contains("hand-picked"))
    }

    @Test func planIsEmptyOnASecondPassOverAnUnchangedLibrary() {
        let desired = [Self.track("a"), Self.track("b")]

        let first = FavoritesOfflineReconciler.plan(
            desired: desired,
            downloaded: [],
            ruleOwnedPending: []
        )
        #expect(first.toDownload.count == 2)

        // Everything the first pass asked for is now queued under the rule.
        let second = FavoritesOfflineReconciler.plan(
            desired: desired,
            downloaded: [],
            ruleOwnedPending: ["a", "b"]
        )
        #expect(second.isEmpty)
    }

    @Test func planReleasesQueuedWorkThatIsNoLongerWanted() {
        let plan = FavoritesOfflineReconciler.plan(
            desired: [Self.track("keep")],
            downloaded: [],
            ruleOwnedPending: ["keep", "unliked"]
        )

        #expect(plan.toDownload.isEmpty)
        #expect(plan.toRelease == ["unliked"])
    }

    @Test func planTreatsAnAlreadyAdoptedDownloadAsSettled() {
        let plan = FavoritesOfflineReconciler.plan(
            desired: [Self.track("a")],
            downloaded: [Self.downloaded("a", owners: [.favoritesRule])],
            ruleOwnedPending: []
        )

        #expect(plan.isEmpty)
    }

    // MARK: - Ownership migration

    @Test func downloadsWrittenBeforeOwnersExistedDecodeAsHandPicked() throws {
        // Exactly the shape the UserDefaults blob used to hold: no owners key.
        let legacy = """
        {
            "trackId": "legacy",
            "fileName": "legacy.mp3",
            "fileSize": 5000,
            "downloadDate": 0,
            "trackName": "Legacy",
            "artistName": "Artist",
            "albumName": "Album",
            "duration": 180,
            "albumId": "album",
            "trackNumber": 3,
            "discNumber": 1,
            "artistId": "artist",
            "productionYear": 2020
        }
        """

        let decoded = try JSONDecoder().decode(DownloadedTrack.self, from: Data(legacy.utf8))

        // Anything already on the device was put there by hand. Decoding it as
        // unowned would let the first reconcile delete the user's music.
        #expect(decoded.owners == [.manual])
        #expect(decoded.trackId == "legacy")
    }

    @Test func ownerColumnRoundTripsAndNeverDecodesToNobody() {
        let both: Set<DownloadOrigin> = [.manual, .favoritesRule]
        #expect(DownloadedTrack.decode(owners: DownloadedTrack.encode(owners: both)) == both)
        #expect(DownloadedTrack.decode(owners: "favoritesRule") == [.favoritesRule])
        // A row we cannot parse must not become a deletion candidate.
        #expect(DownloadedTrack.decode(owners: "") == [.manual])
        #expect(DownloadedTrack.decode(owners: "nonsense") == [.manual])
    }

    // MARK: - Store

    @Test func storeRoundTripsDownloadsAndPendingWork() throws {
        let store = try Self.makeStore()

        store.upsert(Self.downloaded("a", owners: [.favoritesRule]))
        store.upsert(Self.downloaded("b", owners: [.manual, .favoritesRule]))

        let loaded = store.loadDownloads().sorted { $0.trackId < $1.trackId }
        #expect(loaded.map(\.trackId) == ["a", "b"])
        #expect(loaded[0].owners == [.favoritesRule])
        #expect(loaded[1].owners == [.manual, .favoritesRule])

        // Upserting the same ID replaces rather than duplicates.
        store.upsert(Self.downloaded("a", owners: [.manual]))
        #expect(store.loadDownloads().count == 2)
        #expect(store.loadDownloads().first { $0.trackId == "a" }?.owners == [.manual])

        store.remove(trackID: "a")
        #expect(store.loadDownloads().map(\.trackId) == ["b"])

        let pending = PendingDownload(track: Self.track("p"), owners: [.favoritesRule], attempts: 2)
        store.upsertPending(pending)
        let loadedPending = store.loadPending()
        #expect(loadedPending.count == 1)
        #expect(loadedPending[0].track.id == "p")
        #expect(loadedPending[0].owners == [.favoritesRule])
        #expect(loadedPending[0].attempts == 2)

        store.removePending(trackID: "p")
        #expect(store.loadPending().isEmpty)
    }

    @Test func storeImportsTheLegacyUserDefaultsBlobExactlyOnce() throws {
        let suiteName = "favorites-offline-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let legacy = """
        [{
            "trackId": "legacy",
            "fileName": "legacy.mp3",
            "fileSize": 5000,
            "downloadDate": 0,
            "trackName": "Legacy",
            "artistName": "Artist",
            "albumName": "Album",
            "duration": 180,
            "albumId": "album"
        }]
        """
        defaults.set(Data(legacy.utf8), forKey: "downloadedTracks")

        let databaseURL = Self.temporaryDatabaseURL()
        let store = try DownloadStore(databaseURL: databaseURL, defaults: defaults)

        let migrated = store.loadDownloads()
        #expect(migrated.count == 1)
        #expect(migrated[0].owners == [.manual])
        // The multi-megabyte blob does not stay behind in UserDefaults.
        #expect(defaults.data(forKey: "downloadedTracks") == nil)

        // A second open must not re-import (and could not, the key is gone).
        let reopened = try DownloadStore(databaseURL: databaseURL, defaults: defaults)
        #expect(reopened.loadDownloads().count == 1)
    }

    // MARK: - Download quality

    @Test func transcodedSizesAreArithmeticAndOriginalsAreMeasured() {
        let manager = DownloadManager(store: try! Self.makeStore(), defaults: Self.emptyDefaults())

        // A dictated bitrate needs no measuring: 192 kbps is 24,000 bytes/s.
        #expect(manager.bytesPerSecond(for: .medium) == 24_000)
        #expect(manager.bytesPerSecond(for: .low) == 16_000)
        #expect(manager.bytesPerSecond(for: .high) == 40_000)

        // With no originals downloaded, the original falls back to an estimate
        // rather than claiming to know.
        #expect(manager.bytesPerSecond(for: .original) == 110_000)

        // One 200-second, 20 MB original: 100,000 bytes per second.
        manager.downloadedTracks = [
            Self.downloaded("flac", owners: [.manual], fileSize: 20_000_000, duration: 200, quality: .original)
        ]
        #expect(manager.bytesPerSecond(for: .original) == 100_000)

        // Transcodes must not pollute the original's measurement — averaging a
        // FLAC library with 128 kbps files would describe neither.
        manager.downloadedTracks.append(
            Self.downloaded("small", owners: [.manual], fileSize: 3_200_000, duration: 200, quality: .low)
        )
        #expect(manager.bytesPerSecond(for: .original) == 100_000)
    }

    @Test func qualitySurvivesTheStoreAndDefaultsToOriginal() throws {
        let store = try Self.makeStore()

        store.upsert(Self.downloaded("a", owners: [.manual], quality: .medium))
        #expect(store.loadDownloads().first?.quality == .medium)

        let pending = PendingDownload(
            track: Self.track("p"),
            owners: [.favoritesRule],
            attempts: 0,
            quality: .high
        )
        store.upsertPending(pending)
        // A retry, or a resume after the app was killed, must fetch what was
        // originally asked for rather than today's setting.
        #expect(store.loadPending().first?.quality == .high)
    }

    @Test func downloadsWrittenBeforeQualityExistedDecodeAsOriginal() throws {
        let legacy = """
        {
            "trackId": "legacy", "fileName": "legacy.mp3", "fileSize": 5000,
            "downloadDate": 0, "trackName": "Legacy", "artistName": "Artist",
            "albumName": "Album", "albumId": "album"
        }
        """
        let decoded = try JSONDecoder().decode(DownloadedTrack.self, from: Data(legacy.utf8))
        // The old /Download endpoint only ever served the original file.
        #expect(decoded.quality == .original)
    }

    @Test func aPopulatedDatabaseFromBeforeQualityUpgradesInPlace() throws {
        // The devices this shipped to already hold a v1 database with real
        // rows, so the upgrade runs against data, not an empty file. Build that
        // exact starting point — v1 schema plus GRDB's own migration record —
        // and open the current store on top of it.
        let databaseURL = Self.temporaryDatabaseURL()
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let v1 = try DatabaseQueue(path: databaseURL.path)
        try v1.write { db in
            try db.execute(sql: """
                CREATE TABLE downloadedTrack (
                    trackId TEXT PRIMARY KEY, fileName TEXT NOT NULL, fileSize INTEGER NOT NULL,
                    downloadDate DATETIME NOT NULL, trackName TEXT NOT NULL, artistName TEXT NOT NULL,
                    albumName TEXT NOT NULL, duration DOUBLE, albumId TEXT NOT NULL,
                    trackNumber INTEGER, discNumber INTEGER, artistId TEXT,
                    productionYear INTEGER, artworkURL TEXT, owners TEXT NOT NULL)
                """)
            try db.execute(sql: """
                CREATE TABLE pendingDownload (
                    trackId TEXT PRIMARY KEY, owners TEXT NOT NULL,
                    attempts INTEGER NOT NULL, payload BLOB NOT NULL)
                """)
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('createDownloadIndex')")
            try db.execute(sql: """
                INSERT INTO downloadedTrack VALUES
                ('kept', 'kept.flac', 30000000, 0, 'Kept', 'Artist', 'Album', 240, 'album',
                 1, 1, 'artist', 2024, NULL, 'manual,favoritesRule')
                """)
        }
        try v1.close()

        let defaults = Self.emptyDefaults()
        defaults.set(true, forKey: "downloadStoreMigratedFromDefaults")
        let store = try DownloadStore(databaseURL: databaseURL, defaults: defaults)

        let rows = store.loadDownloads()
        #expect(rows.count == 1)
        // The row survives, keeps its owners, and gains the only quality it
        // could have had — deleting or mislabelling it would lose real music.
        #expect(rows[0].trackId == "kept")
        #expect(rows[0].owners == [.manual, .favoritesRule])
        #expect(rows[0].quality == .original)
        #expect(rows[0].fileSize == 30_000_000)

        // And the upgraded schema accepts new writes at other qualities.
        store.upsert(Self.downloaded("new", owners: [.manual], quality: .medium))
        #expect(store.loadDownloads().count == 2)
        #expect(store.loadDownloads().first { $0.trackId == "new" }?.quality == .medium)
    }

    @Test func onlyTranscodesDeclareAFileExtension() {
        #expect(DownloadQuality.original.fileExtension == nil)
        #expect(DownloadQuality.medium.fileExtension == "mp3")
        #expect(DownloadQuality.original.bytesPerSecond == nil)
    }

    // MARK: - Helpers

    private static func emptyDefaults() -> UserDefaults {
        let suiteName = "favorites-offline-tests-\(UUID().uuidString)"
        return UserDefaults(suiteName: suiteName)!
    }

    private static func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("aurelia-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Downloads.sqlite")
    }

    private static func makeStore() throws -> DownloadStore {
        let suiteName = "favorites-offline-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        // Nothing to migrate; the flag keeps the importer out of the way.
        defaults.set(true, forKey: "downloadStoreMigratedFromDefaults")
        return try DownloadStore(databaseURL: temporaryDatabaseURL(), defaults: defaults)
    }
}
