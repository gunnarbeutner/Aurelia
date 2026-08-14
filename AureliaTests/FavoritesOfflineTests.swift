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
@testable import Aurelia

struct FavoritesOfflineTests {

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
        duration: TimeInterval? = 200
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
            owners: owners
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

    // MARK: - Helpers

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
