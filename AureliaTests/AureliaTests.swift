//
//  AureliaTests.swift
//  AureliaTests
//
//  Created by Grafton on 10/17/25.
//

import Testing
import Foundation
import Combine
import UIKit
import SwiftUI
@testable import Aurelia

struct AureliaTests {

    @Test func appearancePreferenceMapsSchemesAndPreservesExistingDarkValue() {
        #expect(AppearancePreference.allCases == [.system, .light, .dark])
        #expect(AppearancePreference.system.colorScheme == nil)
        #expect(AppearancePreference.light.colorScheme == .light)
        #expect(AppearancePreference.dark.colorScheme == .dark)
        #expect(AppearancePreference(rawValue: "always_dark") == .dark)
    }

    @Test func sqliteLibraryCachePersistsTypedMetadataAndScopesUsers() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Library.sqlite")
        let repository = try LibraryRepository(databaseURL: databaseURL)
        let firstScope = try #require(LibraryScope(baseURL: "HTTPS://Music.example/", userID: "one"))
        let secondScope = try #require(LibraryScope(baseURL: "https://music.example", userID: "two"))
        let album = Album(
            id: "album",
            name: "Stored Album",
            artistName: "Stored Artist",
            artistId: "artist",
            year: 2026,
            trackCount: 9,
            artworkURL: "https://music.example/art",
            isFavorite: true
        )
        let artist = Artist(
            id: "artist",
            name: "Stored Artist",
            bio: "Biography",
            albumCount: 1,
            artworkURL: nil,
            isFavorite: true
        )
        let playlist = Playlist(
            id: "playlist",
            name: "Stored Playlist",
            trackCount: 4,
            artworkURL: nil,
            dateCreated: Date(timeIntervalSince1970: 123),
            isFavorite: false
        )

        try await repository.replaceLibrary(
            albums: [album],
            artists: [artist],
            playlists: [playlist],
            in: firstScope,
            syncedAt: Date(timeIntervalSince1970: 456)
        )

        let stored = try await repository.librarySnapshot(in: firstScope)
        let otherUser = try await repository.librarySnapshot(in: secondScope)
        #expect(stored.albums == [album])
        #expect(stored.artists == [artist])
        #expect(stored.playlists == [playlist])
        #expect(stored.lastSyncedAt == Date(timeIntervalSince1970: 456))
        #expect(!otherUser.hasCachedLibrary)
        #expect(otherUser.albums.isEmpty)
    }

    @Test func sqliteRecentlyPlayedUsesTimestampOrderingWithoutAnIDList() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Library.sqlite")
        let repository = try LibraryRepository(databaseURL: databaseURL)
        let scope = try #require(LibraryScope(baseURL: "https://music.example", userID: "listener"))
        let first = Track(
            id: "first",
            name: "First",
            artistName: "Artist",
            albumName: "One",
            duration: 1,
            artworkURL: nil,
            albumId: "album-one"
        )
        let second = Track(
            id: "second",
            name: "Second",
            artistName: "Artist",
            albumName: "Two",
            duration: 1,
            artworkURL: nil,
            albumId: "album-two"
        )

        await repository.recordLocalPlay(first, in: scope, playedAt: Date(timeIntervalSince1970: 10))
        await repository.recordLocalPlay(second, in: scope, playedAt: Date(timeIntervalSince1970: 20))
        await repository.recordLocalPlay(first, in: scope, playedAt: Date(timeIntervalSince1970: 30))

        #expect(await repository.cachedRecentTracks(in: scope, limit: 20).map(\.id) == ["first", "second"])

        await repository.replaceRecentlyPlayed(
            [RecentTrackEntry(track: second, playedAt: Date(timeIntervalSince1970: 40))],
            in: scope
        )
        #expect(await repository.cachedRecentTracks(in: scope, limit: 20).map(\.id) == ["second"])
    }

    @Test func localPlaybackDoesNotOverwriteCachedFavoriteState() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Library.sqlite")
        let repository = try LibraryRepository(databaseURL: databaseURL)
        let scope = try #require(LibraryScope(baseURL: "https://music.example", userID: "listener"))
        let track = Track(
            id: "favorite",
            name: "Favorite",
            artistName: "Artist",
            albumName: "Album",
            duration: 1,
            artworkURL: nil
        )

        await repository.setFavorite(true, for: track, in: scope)
        await repository.recordLocalPlay(track, in: scope)

        let favorites = await repository.favoriteSnapshot(in: scope)
        #expect(favorites.tracks.map(\.id) == ["favorite"])
        #expect(favorites.tracks.first?.isFavorite == true)
    }

    @Test func completeCatalogPersistsRelationshipsAndReplacesOldRows() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Library.sqlite")
        let repository = try LibraryRepository(databaseURL: databaseURL)
        let scope = try #require(LibraryScope(baseURL: "https://music.example", userID: "listener"))
        let artist = Artist(id: "artist", name: "Björk", bio: nil, albumCount: 1, artworkURL: nil)
        let album = Album(
            id: "album",
            name: "Homogenic",
            artistName: artist.name,
            artistId: artist.id,
            year: 1997,
            artworkURL: nil,
            genreIDs: ["electronic"]
        )
        let track = Track(
            id: "track",
            name: "Jóga",
            artistName: artist.name,
            albumName: album.name,
            duration: 300,
            artworkURL: nil,
            indexNumber: 2,
            albumId: album.id,
            artistId: artist.id,
            artistIDs: [artist.id],
            genreIDs: ["electronic"]
        )
        let playlist = Playlist(
            id: "playlist",
            name: "Iceland",
            trackCount: 1,
            artworkURL: nil,
            dateCreated: nil
        )

        try await repository.replaceCompleteLibrary(
            LibraryCatalog(
                albums: [album],
                artists: [artist],
                tracks: [track],
                playlists: [playlist],
                genres: [Genre(id: "electronic", name: "Electronic", albumCount: 1)],
                playlistEntries: [LibraryPlaylistEntry(playlistID: playlist.id, track: track, position: 0)]
            ),
            in: scope
        )

        #expect(try await repository.tracks(inAlbum: album.id, in: scope).map(\.id) == [track.id])
        #expect(try await repository.tracks(forArtist: artist.id, in: scope).map(\.id) == [track.id])
        #expect(try await repository.albums(forArtist: artist.id, in: scope).map(\.id) == [album.id])
        #expect(try await repository.albums(inGenre: "electronic", in: scope).map(\.id) == [album.id])
        #expect(try await repository.tracks(inPlaylist: playlist.id, in: scope).map(\.id) == [track.id])

        try await repository.replaceCompleteLibrary(
            LibraryCatalog(
                albums: [], artists: [], tracks: [], playlists: [], genres: [], playlistEntries: []
            ),
            in: scope
        )
        let empty = try await repository.librarySnapshot(in: scope)
        #expect(empty.albums.isEmpty)
        #expect(empty.artists.isEmpty)
        #expect(empty.tracks.isEmpty)
        #expect(empty.playlists.isEmpty)
        #expect(empty.genres.isEmpty)
        #expect(empty.hasCachedLibrary)
    }

    @Test func stagedFullSyncSurvivesTerminationAndStaysHiddenUntilPromoted() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Library.sqlite")
        let scope = try #require(LibraryScope(baseURL: "https://music.example", userID: "listener"))
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let stale = Album(
            id: "stale",
            name: "Previous Catalog",
            artistName: "Old Artist",
            artistId: "old",
            year: 1990,
            artworkURL: nil,
            genreIDs: nil
        )
        let artist = Artist(id: "artist", name: "Björk", bio: nil, albumCount: 1, artworkURL: nil)
        let album = Album(
            id: "album",
            name: "Homogenic",
            artistName: artist.name,
            artistId: artist.id,
            year: 1997,
            artworkURL: nil,
            genreIDs: ["electronic"]
        )
        let track = Track(
            id: "track",
            name: "Jóga",
            artistName: artist.name,
            albumName: album.name,
            duration: 300,
            artworkURL: nil,
            indexNumber: 2,
            albumId: album.id,
            artistId: artist.id,
            artistIDs: [artist.id],
            genreIDs: ["electronic"]
        )
        let playlist = Playlist(
            id: "playlist",
            name: "Iceland",
            trackCount: 1,
            artworkURL: nil,
            dateCreated: nil
        )

        // A previously synced catalog the interrupted sync must not disturb.
        let repository = try LibraryRepository(databaseURL: databaseURL)
        try await repository.replaceCompleteLibrary(
            LibraryCatalog(
                albums: [stale], artists: [], tracks: [], playlists: [],
                genres: [], playlistEntries: []
            ),
            in: scope
        )
        let baselineRevision = try #require(try await repository.syncState(in: scope)).catalogRevision

        // Stage the first two pages of a new full sync.
        try await repository.appendStagedChunk(
            LibraryCatalog(
                albums: [album], artists: [], tracks: [], playlists: [],
                genres: [Genre(id: "electronic", name: "Electronic", albumCount: 1)],
                playlistEntries: []
            ),
            stage: "albums",
            nextOffset: 1,
            detail: nil,
            startedAt: startedAt,
            in: scope
        )
        try await repository.appendStagedChunk(
            LibraryCatalog(
                albums: [], artists: [artist], tracks: [], playlists: [],
                genres: [], playlistEntries: []
            ),
            stage: "artists",
            nextOffset: 1,
            detail: nil,
            startedAt: startedAt,
            in: scope
        )

        // Readers keep seeing the previous complete catalog, never a partial one.
        let midway = try await repository.librarySnapshot(in: scope)
        #expect(midway.albums.map(\.id) == [stale.id])
        #expect(midway.artists.isEmpty)
        #expect(try await repository.syncState(in: scope)?.catalogRevision == baselineRevision)
        #expect(try await repository.search("Homogenic", filter: .all, in: scope).isEmpty)

        // Reopening the file stands in for a relaunch after termination.
        let reopened = try LibraryRepository(databaseURL: databaseURL)
        let resumed = try #require(try await reopened.stagingProgress(in: scope))
        #expect(resumed.stage == "artists")
        #expect(resumed.nextOffset == 1)
        #expect(resumed.startedAt == startedAt)

        // Resume where the previous run died rather than restarting.
        try await reopened.appendStagedChunk(
            LibraryCatalog(
                albums: [], artists: [], tracks: [track], playlists: [playlist],
                genres: [], playlistEntries: [
                    LibraryPlaylistEntry(playlistID: playlist.id, track: track, position: 0)
                ]
            ),
            stage: "playlistEntries",
            nextOffset: 1,
            detail: playlist.id,
            startedAt: startedAt,
            in: scope
        )
        #expect(try await reopened.stagedPlaylistIDs(in: scope) == [playlist.id])

        try await reopened.promoteStagedLibrary(in: scope, syncedAt: startedAt)

        // The staged catalog is now live, in one step, with relationships intact.
        let promoted = try await reopened.librarySnapshot(in: scope, includeTracks: true)
        #expect(promoted.albums.map(\.id) == [album.id])
        #expect(promoted.artists.map(\.id) == [artist.id])
        #expect(promoted.tracks.map(\.id) == [track.id])
        #expect(try await reopened.tracks(forArtist: artist.id, in: scope).map(\.id) == [track.id])
        #expect(try await reopened.albums(inGenre: "electronic", in: scope).map(\.id) == [album.id])
        #expect(try await reopened.tracks(inPlaylist: playlist.id, in: scope).map(\.id) == [track.id])
        #expect(try await reopened.search("Homogenic", filter: .all, in: scope).isEmpty == false)
        #expect(try await reopened.syncState(in: scope)?.catalogRevision == baselineRevision + 1)

        // Promotion consumes the staged rows and the cursor.
        #expect(try await reopened.stagingProgress(in: scope) == nil)
        #expect(try await reopened.stagedPlaylistIDs(in: scope).isEmpty)
    }

    @Test func discardedStagingLeavesTheLiveCatalogUntouched() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Library.sqlite")
        let repository = try LibraryRepository(databaseURL: databaseURL)
        let scope = try #require(LibraryScope(baseURL: "https://music.example", userID: "listener"))
        let live = Album(
            id: "live",
            name: "Live Catalog",
            artistName: "Artist",
            artistId: "artist",
            year: 2001,
            artworkURL: nil,
            genreIDs: nil
        )

        try await repository.replaceCompleteLibrary(
            LibraryCatalog(
                albums: [live], artists: [], tracks: [], playlists: [],
                genres: [], playlistEntries: []
            ),
            in: scope
        )
        try await repository.appendStagedChunk(
            LibraryCatalog(
                albums: [Album(
                    id: "abandoned",
                    name: "Abandoned",
                    artistName: "Artist",
                    artistId: "artist",
                    year: 2002,
                    artworkURL: nil,
                    genreIDs: nil
                )],
                artists: [], tracks: [], playlists: [], genres: [], playlistEntries: []
            ),
            stage: "albums",
            nextOffset: 1,
            detail: nil,
            startedAt: Date(),
            in: scope
        )

        try await repository.resetStagedLibrary(in: scope)

        #expect(try await repository.stagingProgress(in: scope) == nil)
        let snapshot = try await repository.librarySnapshot(in: scope)
        #expect(snapshot.albums.map(\.id) == [live.id])
    }

    @Test func incrementalDeltaIsAtomicPreservesStateAndAdvancesRevision() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Library.sqlite")
        let repository = try LibraryRepository(databaseURL: databaseURL)
        let scope = try #require(LibraryScope(baseURL: "https://music.example", userID: "listener"))
        let original = Track(
            id: "track",
            name: "Old Name",
            artistName: "Artist",
            albumName: "Album",
            duration: 60,
            artworkURL: nil,
            albumId: "album",
            artistId: "artist"
        )
        try await repository.replaceCompleteLibrary(
            LibraryCatalog(
                albums: [], artists: [], tracks: [original],
                playlists: [], genres: [], playlistEntries: []
            ),
            in: scope,
            syncedAt: Date(timeIntervalSince1970: 100)
        )
        await repository.setFavorite(true, for: original, in: scope)
        let before = try #require(try await repository.syncState(in: scope))

        var changedTrack = original
        changedTrack = Track(
            id: changedTrack.id,
            name: "New Name",
            artistName: changedTrack.artistName,
            albumName: changedTrack.albumName,
            duration: changedTrack.duration,
            artworkURL: changedTrack.artworkURL,
            albumId: changedTrack.albumId,
            artistId: changedTrack.artistId
        )
        let watermark = Date(timeIntervalSince1970: 200)
        let commit = try await repository.applyDelta(
            LibraryDelta(
                tracks: [changedTrack],
                metadataWatermark: watermark,
                userDataWatermark: watermark
            ),
            in: scope
        )

        #expect(commit.baseRevision == before.catalogRevision)
        #expect(commit.revision == before.catalogRevision + 1)
        #expect(try await repository.search("new", filter: .tracks, in: scope).count == 1)
        #expect(try await repository.search("old", filter: .tracks, in: scope).isEmpty)
        #expect(await repository.favoriteSnapshot(in: scope).tracks.first?.isFavorite == true)
        let after = try #require(try await repository.syncState(in: scope))
        #expect(after.metadataWatermark == watermark)

        _ = try await repository.applyDelta(
            LibraryDelta(
                userData: [
                    LibraryUserDataChange(
                        itemID: original.id,
                        isFavorite: false,
                        lastPlayedAt: nil,
                        playCount: nil,
                        playbackPositionTicks: nil
                    )
                ],
                metadataWatermark: watermark,
                userDataWatermark: watermark
            ),
            in: scope
        )
        #expect(await repository.favoriteSnapshot(in: scope).tracks.isEmpty)

        _ = try await repository.applyDelta(
            LibraryDelta(
                removedItemIDs: [original.id],
                metadataWatermark: watermark,
                userDataWatermark: watermark
            ),
            in: scope
        )
        #expect(try await repository.search("new", filter: .tracks, in: scope).isEmpty)
    }

    @Test func watermarkOnlyDeltaDoesNotCreateAWatchRevision() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Library.sqlite")
        let repository = try LibraryRepository(databaseURL: databaseURL)
        let scope = try #require(LibraryScope(baseURL: "https://music.example", userID: "listener"))
        try await repository.replaceCompleteLibrary(
            LibraryCatalog(
                albums: [], artists: [], tracks: [], playlists: [], genres: [], playlistEntries: []
            ),
            in: scope
        )
        let before = try #require(try await repository.syncState(in: scope))
        let watermark = Date(timeIntervalSince1970: 900)
        let commit = try await repository.applyDelta(
            LibraryDelta(metadataWatermark: watermark, userDataWatermark: watermark),
            in: scope
        )
        #expect(!commit.changed)
        #expect(commit.revision == before.catalogRevision)
        #expect(try await repository.syncState(in: scope)?.metadataWatermark == watermark)
    }

    @Test func sqliteFTSSupportsPrefixesDiacriticsFiltersAndScopes() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Library.sqlite")
        let repository = try LibraryRepository(databaseURL: databaseURL)
        let scope = try #require(LibraryScope(baseURL: "https://music.example", userID: "one"))
        let otherScope = try #require(LibraryScope(baseURL: "https://music.example", userID: "two"))
        let artist = Artist(id: "artist", name: "Björk", bio: nil, albumCount: 1, artworkURL: nil)
        let album = Album(id: "album", name: "Homogenic", artistName: "Björk", artistId: "artist", year: 1997, artworkURL: nil)
        let track = Track(id: "track", name: "Jóga", artistName: "Björk", albumName: "Homogenic", duration: 1, artworkURL: nil, albumId: "album", artistId: "artist")
        let playlist = Playlist(id: "playlist", name: "Iceland Essentials", trackCount: 1, artworkURL: nil, dateCreated: nil)
        let catalog = LibraryCatalog(albums: [album], artists: [artist], tracks: [track], playlists: [playlist], genres: [], playlistEntries: [])
        try await repository.replaceCompleteLibrary(catalog, in: scope)
        try await repository.replaceCompleteLibrary(catalog, in: otherScope)

        #expect(try await repository.search("bjork", filter: .artists, in: scope).map(\.id) == ["artist:artist"])
        #expect(try await repository.search("hom", filter: .albums, in: scope).map(\.id) == ["album:album"])
        #expect(try await repository.search("jog", filter: .tracks, in: scope).map(\.id) == ["track:track"])
        #expect(try await repository.search("hom", filter: .tracks, in: scope).map(\.id) == ["track:track"])
        #expect(try await repository.search("hom", filter: .all, in: scope).count == 2)
        #expect(try await repository.search("iceland", filter: .playlists, in: scope).map(\.id) == ["playlist:playlist"])
        #expect(try await repository.search("iceland", filter: .all, in: scope).map(\.id) == ["playlist:playlist"])
        #expect(try await repository.search("iceland", filter: .albums, in: scope).isEmpty)
    }

    @Test func discoverySnapshotPersistsPerLibraryScope() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Library.sqlite")
        let repository = try LibraryRepository(databaseURL: databaseURL)
        let scope = try #require(LibraryScope(baseURL: "https://music.example", userID: "one"))
        let otherScope = try #require(LibraryScope(baseURL: "https://music.example", userID: "two"))
        let track = Track(id: "seed", name: "Seed", artistName: "Artist", albumName: "Album", duration: 1, artworkURL: nil)
        let snapshot = DiscoverySnapshot(
            shelves: [DiscoveryShelf(seed: track, tracks: [track])],
            fallbackTracks: [],
            recentTracks: [track],
            recentSignature: [track.id],
            refreshedAt: Date(timeIntervalSince1970: 100)
        )

        await repository.saveDiscoverySnapshot(snapshot, in: scope)
        #expect(await repository.discoverySnapshot(in: scope) == snapshot)
        #expect(await repository.discoverySnapshot(in: otherScope) == nil)
    }

    @Test func dynamicDiscoverySelectsNeglectedAndUnderplayedTracksStably() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-200 * 24 * 60 * 60)
        let recent = now.addingTimeInterval(-5 * 24 * 60 * 60)
        let candidates = [
            DiscoveryCandidate(
                track: Track(id: "favorite", name: "Favorite", artistName: "A", albumName: "One", duration: 1, artworkURL: nil, artistId: "a"),
                lastPlayedAt: old,
                playCount: 8,
                isFavorite: true
            ),
            DiscoveryCandidate(
                track: Track(id: "former", name: "Former Regular", artistName: "B", albumName: "Two", duration: 1, artworkURL: nil, artistId: "b"),
                lastPlayedAt: old,
                playCount: 3,
                isFavorite: false
            ),
            DiscoveryCandidate(
                track: Track(id: "recent", name: "Recent", artistName: "C", albumName: "Three", duration: 1, artworkURL: nil, artistId: "c"),
                lastPlayedAt: recent,
                playCount: 10,
                isFavorite: true
            ),
            DiscoveryCandidate(
                track: Track(id: "unplayed", name: "Unplayed", artistName: "D", albumName: "Four", duration: 1, artworkURL: nil, artistId: "d"),
                lastPlayedAt: nil,
                playCount: 0,
                isFavorite: false
            ),
            DiscoveryCandidate(
                track: Track(id: "one-play", name: "One Play", artistName: "E", albumName: "Five", duration: 1, artworkURL: nil, artistId: "e"),
                lastPlayedAt: old,
                playCount: 1,
                isFavorite: false
            )
        ]

        let rediscover = DynamicDiscoverySelector.rediscover(from: candidates, now: now)
        let rediscoverAgain = DynamicDiscoverySelector.rediscover(from: candidates, now: now)
        let offPath = DynamicDiscoverySelector.offTheBeatenPath(from: candidates, now: now)

        #expect(Set(rediscover.map(\.id)) == ["favorite", "former"])
        #expect(rediscover == rediscoverAgain)
        #expect(Set(offPath.map(\.id)) == ["unplayed", "one-play"])
    }

    @Test func dynamicDiscoveryCapsRepeatedArtists() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let candidates = (0..<8).map { index in
            DiscoveryCandidate(
                track: Track(
                    id: "track-\(index)",
                    name: "Track \(index)",
                    artistName: index < 6 ? "Same Artist" : "Artist \(index)",
                    albumName: "Album",
                    duration: 1,
                    artworkURL: nil,
                    artistId: index < 6 ? "same" : "artist-\(index)"
                ),
                lastPlayedAt: nil,
                playCount: 0,
                isFavorite: false
            )
        }

        let selected = DynamicDiscoverySelector.offTheBeatenPath(
            from: candidates,
            now: now,
            limit: 8
        )

        #expect(selected.filter { $0.artistId == "same" }.count == 2)
        #expect(selected.count == 4)
    }

    @Test func dailyMixSeedsCombineTasteRegionsAndSongsWithoutRecentTracks() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-30 * 24 * 60 * 60)
        let candidates = (0..<7).map { index in
            DiscoveryCandidate(
                track: Track(
                    id: "track-\(index)",
                    name: "Song \(index)",
                    artistName: "Artist \(index)",
                    albumName: "Album \(index)",
                    duration: 1,
                    artworkURL: nil,
                    artistId: "artist-\(index)",
                    genreIDs: ["genre-\(index % 3)"]
                ),
                lastPlayedAt: old,
                playCount: 7 - index,
                isFavorite: index < 4
            )
        }

        let seeds = DynamicDiscoverySelector.dailyMixSeeds(
            from: candidates,
            recentTrackIDs: ["track-0"],
            now: now
        )

        #expect(seeds.count == 5)
        #expect(!seeds.map(\.track.id).contains("track-0"))
        #expect(Set(seeds.map(\.track.artistId)).count == 5)
        #expect(seeds.prefix(3).allSatisfy { $0.title == "\($0.track.artistName) Mix" })
        #expect(seeds.suffix(2).allSatisfy { $0.title == "\($0.track.name) Mix" })
        #expect(seeds == DynamicDiscoverySelector.dailyMixSeeds(
            from: candidates,
            recentTrackIDs: ["track-0"],
            now: now
        ))
    }

    @Test func decodesAudioMusePluginInfo() throws {
        let data = Data(#"{"Version":"1.4.2","AvailableEndpoints":["GET /AudioMuseAI/health"]}"#.utf8)
        let info = try JSONDecoder().decode(AudioMusePluginInfo.self, from: data)

        #expect(info.version == "1.4.2")
        #expect(info.availableEndpoints == ["GET /AudioMuseAI/health"])
    }

    @Test func decodesAudioMuseProgressAndDetails() throws {
        let data = Data(#"{"task_id":"analysis","task_type":"library","status":"running","progress":"42.5","details":{"status_message":"Analyzing albums"},"running_time_seconds":12}"#.utf8)
        let status = try JSONDecoder().decode(AudioMuseTaskStatus.self, from: data)

        #expect(status.taskId == "analysis")
        #expect(status.progressFraction == 0.425)
        #expect(status.message == "Analyzing albums")
        #expect(status.isActive)
    }

    @Test @MainActor func discoveryExcludesRecentTracksFromDailyMixSeeds() async throws {
        let recentA = Track(id: "recent-a", name: "A", artistName: "Artist A", albumName: "One", duration: 1, artworkURL: nil, artistId: "artist-a")
        let api = FakeDiscoveryAPI()
        let provider = FakeDiscoveryCandidateProvider(candidates: [
            Self.discoveryCandidate(recentA),
            Self.discoveryCandidate(id: "taste-b", artist: "Artist B", genre: "rock"),
            Self.discoveryCandidate(id: "taste-c", artist: "Artist C", genre: "jazz")
        ])
        let scope = try #require(LibraryScope(baseURL: api.baseURL, userID: "user"))
        let viewModel = DiscoveryViewModel(
            api: api,
            recentTracksProvider: { [recentA] },
            snapshotScope: scope,
            candidateProvider: provider
        )

        await viewModel.refresh()

        #expect(!api.requestedMixes.contains("recent-a"))
        #expect(Set(api.requestedMixes) == ["taste-b", "taste-c"])
        #expect(viewModel.recentTracks.map(\.id) == ["recent-a"])
    }

    @Test @MainActor func discoveryBuildsUpToMaximumMixShelves() async throws {
        let api = FakeDiscoveryAPI()
        let provider = FakeDiscoveryCandidateProvider(candidates: (0..<8).map {
            Self.discoveryCandidate(id: "taste-\($0)", artist: "Artist \($0)", genre: "genre-\($0 % 3)")
        })
        let scope = try #require(LibraryScope(baseURL: api.baseURL, userID: "user"))
        let viewModel = DiscoveryViewModel(
            api: api,
            recentTracksProvider: { [] },
            snapshotScope: scope,
            candidateProvider: provider
        )

        await viewModel.refresh()

        #expect(viewModel.shelves.count == DiscoveryViewModel.maximumMixShelfCount)
        #expect(Set(viewModel.shelves.map(\.seed.id)).count == 5)
    }

    @Test @MainActor func discoveryUsesJellyfinRecentlyPlayedStateWhenAvailable() async {
        let local = Track(
            id: "local",
            name: "Local",
            artistName: "Local Artist",
            albumName: "Local Album",
            duration: 1,
            artworkURL: nil
        )
        let api = FakeDiscoveryAPI()
        api.shouldFailRecent = false
        api.serverRecentTracks = [api.audio(id: "server", artist: "Server Artist")]
        let viewModel = DiscoveryViewModel(api: api, recentTracksProvider: { [local] })

        await viewModel.refresh()

        #expect(viewModel.recentTracks.map(\.id) == ["server"])
        #expect(api.requestedMixes.isEmpty)
    }

    @Test func discoveryMixUsesTheSeedArtistAndListsOtherArtistsOnce() {
        let seed = Track(id: "seed", name: "Seed", artistName: "Main Band", albumName: "Album", duration: 1, artworkURL: nil)
        let shelf = DiscoveryShelf(
            seed: seed,
            tracks: [
                Track(id: "1", name: "One", artistName: "Guest A", albumName: "A", duration: 1, artworkURL: nil),
                Track(id: "2", name: "Two", artistName: "Main Band", albumName: "B", duration: 1, artworkURL: nil),
                Track(id: "3", name: "Three", artistName: "guest a", albumName: "C", duration: 1, artworkURL: nil),
                Track(id: "4", name: "Four", artistName: "Guest B", albumName: "D", duration: 1, artworkURL: nil)
            ]
        )

        #expect(shelf.mixTitle == "Main Band Mix")
        #expect(shelf.supportingArtistNames == ["Guest A", "Guest B"])
    }

    @Test @MainActor func discoveryRequiresAudioMuseForDailyMixes() async throws {
        let api = FakeDiscoveryAPI()
        api.audioMuseAvailable = false
        let provider = FakeDiscoveryCandidateProvider(candidates: [
            Self.discoveryCandidate(id: "taste", artist: "Artist", genre: "rock")
        ])
        let scope = try #require(LibraryScope(baseURL: api.baseURL, userID: "user"))
        let viewModel = DiscoveryViewModel(
            api: api,
            recentTracksProvider: { [] },
            snapshotScope: scope,
            candidateProvider: provider
        )

        await viewModel.refresh()

        #expect(viewModel.shelves.isEmpty)
        #expect(api.requestedMixes.isEmpty)
        #expect(viewModel.availability == .notInstalled)
    }

    @Test @MainActor func discoveryUsesAudioMuseWhileAnalysisIsRunning() async throws {
        let api = FakeDiscoveryAPI()
        api.activeAudioMuseTask = try JSONDecoder().decode(
            AudioMuseTaskStatus.self,
            from: Data(
                #"{"task_id":"analysis","task_type":"library-analysis","status":"running","progress":0.5}"#.utf8
            )
        )
        let provider = FakeDiscoveryCandidateProvider(candidates: [
            Self.discoveryCandidate(id: "taste", artist: "Artist", genre: "rock")
        ])
        let scope = try #require(LibraryScope(baseURL: api.baseURL, userID: "user"))
        let viewModel = DiscoveryViewModel(
            api: api,
            recentTracksProvider: { [] },
            snapshotScope: scope,
            candidateProvider: provider
        )

        await viewModel.refresh()

        #expect(api.requestedMixes == ["taste"])
        #expect(viewModel.shelves.count == 1)
        #expect(viewModel.availability == .analyzing(api.activeAudioMuseTask!))
    }

    @Test @MainActor func confirmedAudioMuseDoesNotBecomeNotInstalledAfterTransient404() async throws {
        let api = FakeDiscoveryAPI()
        api.activeAudioMuseTask = try JSONDecoder().decode(
            AudioMuseTaskStatus.self,
            from: Data(#"{"task_id":"analysis","status":"running"}"#.utf8)
        )
        let provider = FakeDiscoveryCandidateProvider(candidates: [
            Self.discoveryCandidate(id: "taste", artist: "Artist", genre: "rock")
        ])
        let scope = try #require(LibraryScope(baseURL: api.baseURL, userID: "user"))
        let viewModel = DiscoveryViewModel(
            api: api,
            recentTracksProvider: { [] },
            snapshotScope: scope,
            candidateProvider: provider
        )

        await viewModel.refresh()
        api.shouldFailAudioMuseInfoAsNotFound = true
        await viewModel.refresh()

        #expect(api.requestedMixes == ["taste", "taste"])
        #expect(viewModel.shelves.count == 1)
        #expect(viewModel.availability == .analyzing(api.activeAudioMuseTask!))
    }

    @Test @MainActor func discoveryDoesNotRepeatRecentHistoryAsStartListeningFallback() async {
        let recent = Track(
            id: "recent",
            name: "Recent",
            artistName: "Recent Artist",
            albumName: "Recent Album",
            duration: 1,
            artworkURL: nil,
            artistId: "recent-artist"
        )
        let api = FakeDiscoveryAPI()
        api.shouldFailMixes = true
        let viewModel = DiscoveryViewModel(api: api, recentTracksProvider: { [recent] })

        await viewModel.refresh()

        #expect(viewModel.shelves.isEmpty)
        #expect(viewModel.recentTracks.map(\.id) == ["recent"])
        #expect(viewModel.fallbackTracks.isEmpty)
        #expect(viewModel.hasContent)
        #expect(viewModel.errorMessage == nil)
    }

    @Test @MainActor func discoveryOffersStartListeningFallbackWithoutHistory() async throws {
        let api = FakeDiscoveryAPI()
        api.shouldFailMixes = true
        let candidate = Self.discoveryCandidate(id: "library", artist: "Artist", genre: "rock")
        let provider = FakeDiscoveryCandidateProvider(candidates: [candidate])
        let scope = try #require(LibraryScope(baseURL: api.baseURL, userID: "user"))
        let viewModel = DiscoveryViewModel(api: api, recentTracksProvider: { [] }, snapshotScope: scope, candidateProvider: provider)

        await viewModel.refresh()

        #expect(viewModel.shelves.isEmpty)
        #expect(viewModel.recentTracks.isEmpty)
        #expect(viewModel.fallbackTracks.map(\.id) == ["library"])
    }

    @Test @MainActor func discoveryRetainsExistingMixesWhenEveryRefreshMixFails() async throws {
        let api = FakeDiscoveryAPI()
        let provider = FakeDiscoveryCandidateProvider(candidates: [Self.discoveryCandidate(id: "taste", artist: "Artist", genre: "rock")])
        let scope = try #require(LibraryScope(baseURL: api.baseURL, userID: "user"))
        let viewModel = DiscoveryViewModel(api: api, recentTracksProvider: { [] }, snapshotScope: scope, candidateProvider: provider)

        await viewModel.refresh()
        let originalShelves = viewModel.shelves
        api.shouldFailMixes = true

        await viewModel.refresh()

        #expect(viewModel.shelves == originalShelves)
        #expect(viewModel.errorMessage?.contains("Showing the previous mixes") == true)
        #expect(viewModel.errorDetails?.contains("unavailable") == true)
    }

    @Test @MainActor func discoveryRetainsGoodDynamicStateWhenCandidateRefreshFails() async throws {
        let api = FakeDiscoveryAPI()
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let provider = FakeDiscoveryCandidateProvider(candidates: [
            Self.discoveryCandidate(
                id: "rediscover",
                artist: "Artist",
                genre: "rock",
                playCount: 3,
                isFavorite: true,
                lastPlayedAt: old
            ),
            Self.discoveryCandidate(id: "off-path", artist: "Other", genre: "jazz")
        ])
        let scope = try #require(LibraryScope(baseURL: api.baseURL, userID: "user"))
        let viewModel = DiscoveryViewModel(
            api: api,
            recentTracksProvider: { [] },
            snapshotScope: scope,
            candidateProvider: provider,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        await viewModel.refresh()
        let originalShelves = viewModel.shelves
        let originalRediscover = viewModel.rediscoverTracks
        let originalOffPath = viewModel.offTheBeatenPathTracks
        await provider.setCandidates([])

        await viewModel.refresh()

        #expect(viewModel.shelves == originalShelves)
        #expect(viewModel.rediscoverTracks == originalRediscover)
        #expect(viewModel.offTheBeatenPathTracks == originalOffPath)
    }

    @Test @MainActor func discoveryTreatsRecentTracksAsContentWhenMixesAreEmpty() async {
        let recent = Track(
            id: "recent",
            name: "Recent",
            artistName: "Recent Artist",
            albumName: "Recent Album",
            duration: 1,
            artworkURL: nil,
            artistId: "recent-artist"
        )
        let api = FakeDiscoveryAPI()
        api.shouldReturnEmptyMixes = true
        let viewModel = DiscoveryViewModel(api: api, recentTracksProvider: { [recent] })

        await viewModel.refresh()

        #expect(viewModel.shelves.isEmpty)
        #expect(viewModel.recentTracks.map(\.id) == ["recent"])
        #expect(viewModel.hasContent)
        #expect(viewModel.errorMessage == nil)
    }

    @Test func jellyfinHTTPErrorIncludesStatusAndServerMessage() {
        let withMessage = JellyfinError.httpError(
            statusCode: 502,
            message: "AudioMuse backend unavailable"
        )
        let withoutMessage = JellyfinError.httpError(statusCode: 503, message: nil)

        #expect(withMessage.localizedDescription == "Server returned HTTP 502: AudioMuse backend unavailable")
        #expect(withoutMessage.localizedDescription == "Server returned HTTP 503.")
    }

    @Test @MainActor func discoveryRestoresCachedMixesWithoutRefetching() async throws {
        let defaultsName = "DiscoveryCacheTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let cache = DiscoveryCache(defaults: defaults, key: "snapshot")
        let recent = Track(
            id: "recent",
            name: "Recent",
            artistName: "Artist",
            albumName: "Album",
            duration: 1,
            artworkURL: nil,
            artistId: "artist"
        )
        let initialAPI = FakeDiscoveryAPI()
        let initial = DiscoveryViewModel(
            api: initialAPI,
            recentTracksProvider: { [recent] },
            cache: cache
        )
        await initial.refresh()

        let restoredAPI = FakeDiscoveryAPI()
        let restored = DiscoveryViewModel(
            api: restoredAPI,
            recentTracksProvider: { [recent] },
            cache: cache
        )
        await restored.loadIfNeeded()

        #expect(restored.hasContent)
        #expect(restored.shelves == initial.shelves)
        #expect(restoredAPI.requestedMixes.isEmpty)
    }

    @Test @MainActor func discoveryStagesAutomaticRefreshUntilNextActivation() async throws {
        var currentDate = Date(timeIntervalSince1970: 1_800_000_000)
        let api = FakeDiscoveryAPI()
        let provider = FakeDiscoveryCandidateProvider(candidates: [
            Self.discoveryCandidate(id: "taste-a", artist: "Artist A", genre: "rock")
        ])
        let scope = try #require(LibraryScope(baseURL: api.baseURL, userID: "user"))
        let viewModel = DiscoveryViewModel(
            api: api,
            recentTracksProvider: { [] },
            snapshotScope: scope,
            candidateProvider: provider,
            now: { currentDate }
        )

        await viewModel.refresh()
        #expect(viewModel.shelves.first?.seed.id == "taste-a")

        await provider.replace(with: [
            Self.discoveryCandidate(id: "taste-b", artist: "Artist B", genre: "jazz")
        ])

        // The current day's discovery shelves remain stable, even when recent
        // playback changes underneath them.
        await viewModel.loadIfNeeded(publishResult: false)
        await viewModel.activate()

        #expect(viewModel.shelves.first?.seed.id == "taste-a")

        // Once a new day begins, prepare the next snapshot without rearranging
        // the visible page. It is adopted on the following activation.
        currentDate = currentDate.addingTimeInterval(24 * 60 * 60)
        await viewModel.loadIfNeeded(publishResult: false)

        #expect(viewModel.shelves.first?.seed.id == "taste-a")

        await viewModel.activate()

        #expect(viewModel.shelves.first?.seed.id == "taste-b")
    }

    @Test @MainActor func discoveryExplicitRefreshPublishesStagedChangesImmediately() async throws {
        let api = FakeDiscoveryAPI()
        let provider = FakeDiscoveryCandidateProvider(candidates: [
            Self.discoveryCandidate(id: "taste-a", artist: "Artist A", genre: "rock")
        ])
        let scope = try #require(LibraryScope(baseURL: api.baseURL, userID: "user"))
        let viewModel = DiscoveryViewModel(api: api, recentTracksProvider: { [] }, snapshotScope: scope, candidateProvider: provider)

        await viewModel.refresh()
        await provider.replace(with: [
            Self.discoveryCandidate(id: "taste-b", artist: "Artist B", genre: "jazz")
        ])
        await viewModel.loadIfNeeded(publishResult: false)
        #expect(viewModel.shelves.first?.seed.id == "taste-a")

        await viewModel.refresh()

        #expect(viewModel.shelves.first?.seed.id == "taste-b")
    }

    @Test @MainActor func favoritesRevalidatesWhenStaleOrExpiredAndPTRAlwaysRefreshes() async {
        var currentDate = Date(timeIntervalSince1970: 1_000)
        var fetchCount = 0
        let expected = Self.favoriteSnapshot(id: "one")
        let viewModel = FavoritesViewModel(
            revalidationInterval: 300,
            now: { currentDate },
            fetcher: {
                fetchCount += 1
                return expected
            }
        )

        await viewModel.activate()
        await viewModel.activate()
        #expect(fetchCount == 1)

        currentDate = currentDate.addingTimeInterval(301)
        await viewModel.activate()
        #expect(fetchCount == 2)

        await viewModel.refresh()
        #expect(fetchCount == 3)

        viewModel.markStale()
        await viewModel.activate()
        #expect(fetchCount == 4)
    }

    @Test @MainActor func favoriteMutationsUpdateTheVisibleSnapshotIncrementally() {
        let viewModel = FavoritesViewModel(fetcher: { .empty })
        let track = Track(
            id: "track",
            name: "Track",
            artistName: "Artist",
            albumName: "Album",
            duration: 1,
            artworkURL: nil
        )
        let album = Album(
            id: "album",
            name: "Album",
            artistName: "Artist",
            artistId: "artist",
            year: 2026,
            artworkURL: nil
        )
        let artist = Artist(
            id: "artist",
            name: "Artist",
            bio: nil,
            albumCount: 1,
            artworkURL: nil
        )

        viewModel.apply(.track(track, isFavorite: true))
        viewModel.apply(.album(album, isFavorite: true))
        viewModel.apply(.artist(artist, isFavorite: true))

        #expect(viewModel.tracks.map(\.id) == ["track"])
        #expect(viewModel.albums.map(\.id) == ["album"])
        #expect(viewModel.artists.map(\.id) == ["artist"])
        #expect(viewModel.tracks.first?.isFavorite == true)

        viewModel.apply(.track(track, isFavorite: false))
        viewModel.apply(.album(album, isFavorite: false))
        viewModel.apply(.artist(artist, isFavorite: false))

        #expect(viewModel.isEmpty)
    }

    @Test @MainActor func failedFavoritesRevalidationKeepsExistingContent() async {
        var shouldFail = false
        let expected = Self.favoriteSnapshot(id: "kept")
        let viewModel = FavoritesViewModel(fetcher: {
            if shouldFail {
                throw FavoritesTestError.failed
            }
            return expected
        })

        await viewModel.activate()
        shouldFail = true
        viewModel.markStale()
        await viewModel.activate()

        #expect(viewModel.snapshot == expected)
        #expect(viewModel.initialErrorMessage == nil)
        #expect(viewModel.revalidationErrorMessage != nil)
    }

    @Test @MainActor func signedBuildCanAccessKeychain() {
        let key = "signing-verification-\(UUID().uuidString)"
        let value = UUID().uuidString
        defer { KeychainService.shared.remove(for: key) }

        KeychainService.shared.store(value, for: key)

        #expect(KeychainService.shared.retrieve(for: key) == value)
    }

    @Test @MainActor func albumArtistNavigationUsesTheAlbumArtistIdentifier() {
        let coordinator = NavigationCoordinator()
        let album = Album(
            id: "album",
            name: "Album",
            artistName: "Band",
            artistId: "band-id",
            year: 2026,
            artworkURL: nil
        )

        coordinator.navigateToArtist(for: album)

        #expect(coordinator.pendingArtistNavigation?.id == "band-id")
        #expect(coordinator.pendingArtistNavigation?.name == "Band")
    }

    @Test func downloadedAlbumFormatsItsYearWithoutLocaleGrouping() {
        let track = DownloadedTrack(
            trackId: "track",
            fileName: "track.m4a",
            fileSize: 1,
            downloadDate: Date(timeIntervalSince1970: 0),
            trackName: "Track",
            artistName: "Band",
            albumName: "Album",
            duration: 1,
            albumId: "album",
            trackNumber: 1,
            discNumber: 1,
            artistId: "band",
            productionYear: 2026,
            artworkURL: nil
        )
        let album = DownloadedAlbum(
            albumId: "album",
            albumName: "Album",
            artistName: "Band",
            artistId: "band",
            productionYear: 2026,
            tracks: [track]
        )

        #expect(album.productionYearText == "2026")
        #expect(album.toAlbum().artistId == "band")
    }

    @Test func albumNamesIncludeTheYearWhenAvailable() {
        let dated = Track(
            id: "dated",
            name: "Track",
            artistName: "Artist",
            albumName: "Album",
            duration: 1,
            artworkURL: nil,
            productionYear: 1999
        )
        let undated = Track(
            id: "undated",
            name: "Track",
            artistName: "Artist",
            albumName: "Album",
            duration: 1,
            artworkURL: nil
        )

        #expect(dated.albumNameWithYear == "Album (1999)")
        #expect(undated.albumNameWithYear == "Album")

        let album = Album(
            id: "album",
            name: "Album",
            artistName: "Artist",
            artistId: "artist",
            year: 1999,
            artworkURL: nil
        )
        let albumWithoutYear = Album(
            id: "undated-album",
            name: "Album",
            artistName: "Artist",
            artistId: "artist",
            year: nil,
            artworkURL: nil
        )

        #expect(album.nameWithYear == "Album (1999)")
        #expect(albumWithoutYear.nameWithYear == "Album")
    }

    private static func favoriteSnapshot(id: String) -> FavoritesSnapshot {
        FavoritesSnapshot(
            tracks: [
                Track(
                    id: id,
                    name: "Favorite",
                    artistName: "Artist",
                    albumName: "Album",
                    duration: 1,
                    artworkURL: nil,
                    isFavorite: true
                )
            ],
            albums: [],
            artists: []
        )
    }

    private static func discoveryCandidate(
        _ track: Track,
        genre: String? = nil,
        playCount: Int = 5,
        isFavorite: Bool = true,
        lastPlayedAt: Date? = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> DiscoveryCandidate {
        let enrichedTrack = Track(
            id: track.id,
            name: track.name,
            sortName: track.sortName,
            artistName: track.artistName,
            albumName: track.albumName,
            duration: track.duration,
            artworkURL: track.artworkURL,
            isFavorite: track.isFavorite,
            indexNumber: track.indexNumber,
            parentIndexNumber: track.parentIndexNumber,
            albumId: track.albumId,
            artistId: track.artistId,
            artistIDs: track.artistIDs,
            genreIDs: genre.map { [$0] },
            playlistEntryID: track.playlistEntryID,
            productionYear: track.productionYear
        )
        return DiscoveryCandidate(
            track: enrichedTrack,
            lastPlayedAt: lastPlayedAt,
            playCount: playCount,
            isFavorite: isFavorite
        )
    }

    private static func discoveryCandidate(
        id: String,
        artist: String,
        genre: String,
        playCount: Int = 5,
        isFavorite: Bool = true,
        lastPlayedAt: Date? = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> DiscoveryCandidate {
        discoveryCandidate(
            Track(
                id: id,
                name: "Song \(id)",
                artistName: artist,
                albumName: "Album",
                duration: 1,
                artworkURL: nil,
                artistId: artist.lowercased().replacingOccurrences(of: " ", with: "-")
            ),
            genre: genre,
            playCount: playCount,
            isFavorite: isFavorite,
            lastPlayedAt: lastPlayedAt
        )
    }

    private enum FavoritesTestError: Error {
        case failed
    }

    @Test func recognizesLibraryLoadCancellationErrors() {
        #expect(isLibraryLoadCancellation(CancellationError()))
        #expect(isLibraryLoadCancellation(URLError(.cancelled)))
        #expect(!isLibraryLoadCancellation(URLError(.timedOut)))
    }

    @Test func playbackProgressPublishesIndependently() {
        let playerManager = PlayerManager.shared
        var playerManagerUpdateCount = 0
        var progressUpdateCount = 0
        let playerManagerObservation = playerManager.objectWillChange.sink {
            playerManagerUpdateCount += 1
        }
        let progressObservation = playerManager.playbackProgress.objectWillChange.sink {
            progressUpdateCount += 1
        }
        let originalTime = playerManager.currentTime

        playerManager.playbackProgress.update(to: originalTime + 1)

        #expect(playerManagerUpdateCount == 0)
        #expect(progressUpdateCount == 1)

        playerManager.playbackProgress.update(to: originalTime)
        withExtendedLifetime((playerManagerObservation, progressObservation)) {}
    }

    @Test func explicitSeekToZeroDoesNotTriggerRestartRecovery() {
        let synchronizedTime = PlaybackRestartRecovery.synchronizedPreviousTime(
            observerTime: 177,
            authoritativeTime: 0
        )

        #expect(synchronizedTime == 0)
        #expect(!PlaybackRestartRecovery.shouldRecover(
            newTime: 0,
            previousTime: synchronizedTime,
            trackedTrackID: "track",
            currentTrackID: "track",
            isSeeking: false
        ))
        #expect(PlaybackRestartRecovery.shouldRecover(
            newTime: 0,
            previousTime: 177,
            trackedTrackID: "track",
            currentTrackID: "track",
            isSeeking: false
        ))
    }

    @Test @MainActor func imageMemoryCacheHitsAreSynchronous() {
        let url = URL(string: "https://aurelia.test/artwork/\(UUID().uuidString)")!
        let image = UIImage()

        ImageCache.shared.cacheMemoryImage(image, for: url)

        #expect(ImageCache.shared.cachedMemoryImage(for: url) === image)
    }

    @Test @MainActor func instantMixUsesAudioMuseCompatibleFields() {
        let queryItems = JellyfinService.instantMixQueryItems(userId: "user", limit: 50)
        let fields = queryItems
            .filter { $0.name == "Fields" }
            .compactMap(\.value)

        #expect(fields == ["PrimaryImageAspectRatio", "MediaSources"])
        #expect(fields.allSatisfy { !$0.contains(",") })
        #expect(queryItems.contains(URLQueryItem(name: "EnableUserData", value: "true")))
    }

    @Test func recentlyPlayedRequestsServerUserHistory() {
        let queryItems = JellyfinService.recentlyPlayedQueryItems(userId: "user", limit: 20)

        #expect(queryItems.contains(URLQueryItem(name: "UserId", value: "user")))
        #expect(queryItems.contains(URLQueryItem(name: "IncludeItemTypes", value: "Audio")))
        #expect(queryItems.contains(URLQueryItem(name: "SortBy", value: "DatePlayed")))
        #expect(queryItems.contains(URLQueryItem(name: "SortOrder", value: "Descending")))
        #expect(queryItems.contains(URLQueryItem(name: "IsPlayed", value: "true")))
        #expect(queryItems.contains(URLQueryItem(name: "EnableUserData", value: "true")))
    }

    @Test func recentlyPlayedTracksBecomeDistinctAlbumsInServerOrder() {
        let first = BaseItemDto(
            Id: "track-a1",
            Name: "A1",
            Type: .Audio,
            Album: "Album A",
            AlbumArtist: "Artist A",
            AlbumId: "album-a",
            AlbumPrimaryImageTag: "tag-a",
            ArtistItems: [NameIdPair(Name: "Artist A", Id: "artist-a")],
            ProductionYear: 2026
        )
        let duplicateAlbum = BaseItemDto(
            Id: "track-a2",
            Name: "A2",
            Type: .Audio,
            Album: "Album A",
            AlbumArtist: "Artist A",
            AlbumId: "album-a"
        )
        let second = BaseItemDto(
            Id: "track-b",
            Name: "B",
            Type: .Audio,
            Album: "Album B",
            AlbumArtist: "Artist B",
            AlbumId: "album-b"
        )

        let albums = recentlyPlayedAlbums(
            from: [first, duplicateAlbum, second],
            baseURL: "https://jellyfin.test"
        )

        #expect(albums.map(\.id) == ["album-a", "album-b"])
        #expect(albums.first?.artistId == "artist-a")
        #expect(albums.first?.artworkURL?.contains("/Items/album-a/Images/Primary") == true)
    }

    @Test @MainActor func mediaNavigationUsesKnownTrackAndArtistIdentifiers() {
        let coordinator = NavigationCoordinator()
        let track = Track(
            id: "track-id",
            name: "Track",
            artistName: "Artist",
            albumName: "Album",
            duration: 1,
            artworkURL: "https://aurelia.test/album.jpg",
            albumId: "album-id",
            artistId: "artist-id",
            productionYear: 2026
        )

        coordinator.navigateToAlbum(for: track)
        #expect(coordinator.pendingAlbumNavigation?.id == "album-id")
        #expect(coordinator.pendingAlbumNavigation?.artistId == "artist-id")

        coordinator.navigateToArtist(for: track)
        #expect(coordinator.pendingArtistNavigation?.id == "artist-id")
        #expect(coordinator.pendingArtistNavigation?.artworkURL == nil)

        coordinator.pendingArtistNavigation = nil
        coordinator.navigateToArtist(
            for: Album(
                id: "album-id",
                name: "Album",
                artistName: "Artist",
                artistId: "artist-id",
                year: 2026,
                artworkURL: "https://aurelia.test/album.jpg"
            )
        )
        #expect(coordinator.pendingArtistNavigation?.id == "artist-id")
        #expect(coordinator.pendingArtistNavigation?.artworkURL == nil)
    }

    @Test @MainActor func waveformBarsStayInsidePlayerViewport() {
        let heights = (0..<60).map { CGFloat(($0 % 8) + 1) / 8 }

        for viewportWidth in [280.0, 335.0, 353.0, 390.0] {
            let size = CGSize(width: viewportWidth, height: 32)
            let rects = WaveformView.barRects(in: size, heights: heights)

            #expect(rects.count == heights.count)
            #expect(rects.allSatisfy { $0.minX >= 0 && $0.maxX <= size.width + 0.001 })
            #expect(rects.allSatisfy { $0.minY >= 0 && $0.maxY <= size.height + 0.001 })
            #expect(abs((rects.last?.maxX ?? 0) - size.width) < 0.001)
        }
    }

    @Test @MainActor func nowPlayingArtworkScalesWithTheViewportOnBothAxes() {
        // A taller window earns a bigger square, with no fixed ceiling.
        let phone = NowPlayingLayout.artworkSize(forWidth: 393, height: 852)
        let splitWindow = NowPlayingLayout.artworkSize(forWidth: 700, height: 1000)
        let largeWindow = NowPlayingLayout.artworkSize(forWidth: 1200, height: 1400)
        #expect(splitWindow > phone)
        #expect(largeWindow > splitWindow)
        #expect(largeWindow > 320)

        // Height is the binding constraint in a short, wide viewport, so the
        // controls below the artwork keep their room.
        let shortWide = NowPlayingLayout.artworkSize(forWidth: 1400, height: 500)
        #expect(shortWide <= 500 * NowPlayingLayout.artworkHeightFraction + 0.001)

        // Width binds in a tall, narrow one.
        let tallNarrow = NowPlayingLayout.artworkSize(forWidth: 380, height: 1200)
        #expect(tallNarrow <= 380 * NowPlayingLayout.artworkWidthFraction + 0.001)

        #expect(NowPlayingLayout.artworkSize(forWidth: 0, height: 0) == 0)
    }

    @Test @MainActor func nowPlayingArtworkRemainsCenteredAtIPhoneWidths() {
        for screenWidth in [320.0, 375.0, 393.0, 430.0] {
            let contentWidth = NowPlayingLayout.contentWidth(for: screenWidth)
            let artworkWidth = NowPlayingLayout.artworkSize(
                forWidth: screenWidth,
                height: 852
            )
            let artworkOrigin = NowPlayingLayout.horizontalPadding
                + (contentWidth - artworkWidth) / 2

            #expect(abs(
                contentWidth + NowPlayingLayout.horizontalPadding * 2 - screenWidth
            ) < 0.001)
            #expect(artworkWidth <= contentWidth)
            #expect(abs((artworkOrigin + artworkWidth / 2) - screenWidth / 2) < 0.001)
        }
    }

    @Test @MainActor func regularNowPlayingColumnsFillAvailableWidth() {
        for screenWidth in [700.0, 768.0, 1024.0, 1280.0] {
            let columns = NowPlayingLayout.regularColumnWidths(for: screenWidth)
            let occupiedWidth = NowPlayingLayout.regularHorizontalPadding * 2
                + columns.player
                + NowPlayingLayout.regularColumnSpacing
                + columns.queue

            #expect(abs(occupiedWidth - screenWidth) < 0.001)
            #expect(columns.player > 0)
            #expect(abs(columns.player - columns.queue) < 0.001)
        }
    }

    @Test @MainActor func shortWidePlayerUsesCondensedColumn() {
        let shortColumns = NowPlayingLayout.regularColumnWidths(for: 1200)
        #expect(NowPlayingLayout.usesCondensedPlayerColumn(
            columnWidth: shortColumns.player,
            viewportHeight: 460
        ))

        let mediumColumns = NowPlayingLayout.regularColumnWidths(for: 760)
        #expect(!NowPlayingLayout.usesCondensedPlayerColumn(
            columnWidth: mediumColumns.player,
            viewportHeight: 620
        ))

        let condensedArtwork = NowPlayingLayout.condensedArtworkSize(
            columnWidth: shortColumns.player,
            viewportHeight: 460
        )
        #expect(condensedArtwork <= shortColumns.player * 0.32 + 0.001)
        #expect(condensedArtwork <= 460 * 0.37 + 0.001)
    }

    @Test @MainActor func tallRegularSingleColumnUsesSmallerArtworkThanPhoneLayout() {
        let phoneArtwork = NowPlayingLayout.singleColumnArtworkSize(
            forWidth: 520,
            height: 800,
            isCompactWidth: true
        )
        let regularArtwork = NowPlayingLayout.singleColumnArtworkSize(
            forWidth: 520,
            height: 800,
            isCompactWidth: false
        )

        #expect(phoneArtwork == NowPlayingLayout.artworkSize(forWidth: 520, height: 800))
        #expect(regularArtwork < phoneArtwork)
        #expect(regularArtwork == 260)
    }

    @Test @MainActor func nowPlayingUsesColumnsOnlyForRegularWidthLandscapeGeometry() {
        #expect(NowPlayingLayout.usesTwoColumns(
            isCompactWidth: false,
            screenWidth: 1366,
            screenHeight: 1024
        ))
        #expect(!NowPlayingLayout.usesTwoColumns(
            isCompactWidth: false,
            screenWidth: 1024,
            screenHeight: 1366
        ))
        #expect(!NowPlayingLayout.usesTwoColumns(
            isCompactWidth: false,
            screenWidth: 1024,
            screenHeight: 1024
        ))
        #expect(!NowPlayingLayout.usesTwoColumns(
            isCompactWidth: false,
            screenWidth: 1600,
            screenHeight: 1375
        ))
        #expect(!NowPlayingLayout.usesTwoColumns(
            isCompactWidth: true,
            screenWidth: 1366,
            screenHeight: 768
        ))
    }

    @Test @MainActor func airPlayAnchorTracksTheVisibleTopBarButton() {
        #expect(NowPlayingLayout.airPlayTrailingPadding(usesTwoColumns: true) == 72)
        #expect(NowPlayingLayout.airPlayTrailingPadding(usesTwoColumns: false) == 64)
    }

    @Test @MainActor func nowPlayingQueueSeparatesHistoryFromUpcomingTracks() {
        let current = Track(
            id: "current",
            name: "Current",
            artistName: "Artist",
            albumName: "Album",
            duration: 0,
            artworkURL: nil
        )
        let played = Track(
            id: "played",
            name: "Played",
            artistName: "Artist",
            albumName: "Album",
            duration: 0,
            artworkURL: nil
        )
        #expect(NowPlayingQueueProjection.visibleHistory(
            [current, played],
            currentTrackID: current.id
        ).map(\.id) == [played.id])
        #expect(NowPlayingQueueProjection.visibleHistory(
            [],
            currentTrackID: current.id
        ).isEmpty)
        #expect(NowPlayingQueueProjection.upNextIndices(
            currentIndex: 3,
            queueCount: 7
        ) == [4, 5, 6])
        #expect(NowPlayingQueueProjection.upNextIndices(
            currentIndex: 6,
            queueCount: 7
        ).isEmpty)
    }

    @Test @MainActor func playbackHistoryRecordsTransitionsNotRestoredQueuePositions() {
        let playerManager = PlayerManager()
        let first = Track(
            id: "first",
            name: "First",
            artistName: "Artist",
            albumName: "Album",
            duration: 0,
            artworkURL: nil
        )
        let second = Track(
            id: "second",
            name: "Second",
            artistName: "Artist",
            albumName: "Album",
            duration: 0,
            artworkURL: nil
        )

        playerManager.recordPlaybackTransition(to: first)
        #expect(playerManager.playbackHistory.isEmpty)

        playerManager.recordPlaybackTransition(to: second)
        #expect(playerManager.playbackHistory.map(\.id) == [first.id])
    }

    @Test @MainActor func upNextReorderingUsesInsertionSemanticsInBothDirections() {
        #expect(UpNextQueueInteraction.moveDestination(from: 2, onto: 5) == 6)
        #expect(UpNextQueueInteraction.moveDestination(from: 5, onto: 2) == 2)
        #expect(UpNextQueueInteraction.hystereticTargetIndex(
            origin: 3,
            current: 3,
            translation: 40,
            lowerBound: 1,
            upperBound: 6
        ) == 3)
        #expect(UpNextQueueInteraction.hystereticTargetIndex(
            origin: 3,
            current: 3,
            translation: 41,
            lowerBound: 1,
            upperBound: 6
        ) == 4)
        #expect(UpNextQueueInteraction.hystereticTargetIndex(
            origin: 3,
            current: 4,
            translation: 40,
            lowerBound: 1,
            upperBound: 6
        ) == 4)
        #expect(UpNextQueueInteraction.hystereticTargetIndex(
            origin: 3,
            current: 4,
            translation: 20,
            lowerBound: 1,
            upperBound: 6
        ) == 3)
        #expect(UpNextQueueInteraction.visualOffset(
            for: 3,
            origin: 3,
            target: 5,
            translation: 97
        ) == 97)
        #expect(UpNextQueueInteraction.visualOffset(
            for: 4,
            origin: 3,
            target: 5,
            translation: 97
        ) == -UpNextQueueInteraction.rowStride)
        #expect(UpNextQueueInteraction.visualOffset(
            for: 5,
            origin: 5,
            target: 3,
            translation: -97
        ) == -97)
        #expect(UpNextQueueInteraction.visualOffset(
            for: 4,
            origin: 5,
            target: 3,
            translation: -97
        ) == UpNextQueueInteraction.rowStride)
        #expect(UpNextQueueInteraction.swipeOffset(
            startOffset: -88,
            translation: 20,
            revealWidth: 88
        ) == -68)
        #expect(UpNextQueueInteraction.swipeOffset(
            startOffset: -88,
            translation: 88,
            revealWidth: 88
        ) == 0)
        #expect(UpNextQueueInteraction.swipeOffset(
            startOffset: -88,
            translation: 120,
            revealWidth: 88
        ) == 0)
        #expect(UpNextQueueInteraction.settledSwipeOffset(
            startOffset: -88,
            predictedTranslation: 60,
            revealWidth: 88
        ) == 0)
    }

    @Test @MainActor func playerDismissalTracksOnlyDownwardVerticalDragsOneToOne() {
        #expect(PlayerDismissalInteraction.offset(for: CGSize(width: 0, height: 96)) == 96)
        #expect(PlayerDismissalInteraction.offset(for: CGSize(width: 0, height: -96)) == 0)
        #expect(PlayerDismissalInteraction.offset(for: CGSize(width: 96, height: 48)) == 0)
    }

    @Test @MainActor func playerDismissalUsesDistanceOrProjectedVelocity() {
        #expect(PlayerDismissalInteraction.shouldDismiss(
            translation: CGSize(width: 0, height: 151),
            predictedEndTranslation: CGSize(width: 0, height: 151)
        ))
        #expect(PlayerDismissalInteraction.shouldDismiss(
            translation: CGSize(width: 0, height: 80),
            predictedEndTranslation: CGSize(width: 0, height: 301)
        ))
        #expect(!PlayerDismissalInteraction.shouldDismiss(
            translation: CGSize(width: 0, height: 80),
            predictedEndTranslation: CGSize(width: 0, height: 250)
        ))
    }

    @Test func keyboardShortcutsFollowMusicAndNavigationConventions() {
        #expect(AureliaShortcuts.playPause.key == .space)
        #expect(AureliaShortcuts.playPause.modifiers.isEmpty)
        #expect(AureliaShortcuts.previousTrack.key == .leftArrow)
        #expect(AureliaShortcuts.previousTrack.modifiers.isEmpty)
        #expect(AureliaShortcuts.nextTrack.key == .rightArrow)
        #expect(AureliaShortcuts.nextTrack.modifiers.isEmpty)
        #expect(AureliaShortcuts.seekBackward.modifiers == [.option, .command])
        #expect(AureliaShortcuts.seekForward.modifiers == [.option, .command])
        #expect(AureliaShortcuts.focusSearch.key == "f")
        #expect(AureliaShortcuts.focusSearch.modifiers == .command)
        #expect(AureliaShortcuts.navigateBack.key == .escape)
        #expect(AureliaShortcuts.navigateBack.modifiers.isEmpty)
        #expect(AureliaShortcuts.tab(5).key == "5")
        #expect(AureliaShortcuts.tab(5).modifiers == .command)
    }

    @Test @MainActor func libraryScrollIndexGroupsLettersNumbersAndDecades() {
        let alphabetical = LibraryScrollIndexBuilder.alphabetical([
            (id: "numeric", title: "12 Moons"),
            (id: "alpha", title: "Äther"),
            (id: "another-alpha", title: "Avalon"),
            (id: "beta", title: "Boards of Canada")
        ])
        let decades = LibraryScrollIndexBuilder.decades([
            (id: "new", year: 2024),
            (id: "same-decade", year: 2020),
            (id: "old", year: 1997),
            (id: "unknown", year: nil)
        ])

        #expect(alphabetical.count == 37)
        #expect(alphabetical.first == LibraryScrollIndexEntry(label: "#", targetID: nil))
        #expect(alphabetical.first { $0.label == "1" }?.targetID == "numeric")
        #expect(alphabetical.first { $0.label == "A" }?.targetID == "alpha")
        #expect(alphabetical.first { $0.label == "B" }?.targetID == "beta")
        #expect(alphabetical.first { $0.label == "Z" }?.targetID == nil)
        #expect(decades == [
            LibraryScrollIndexEntry(label: "2020s", targetID: "new"),
            LibraryScrollIndexEntry(label: "1990s", targetID: "old"),
            LibraryScrollIndexEntry(label: "#", targetID: "unknown")
        ])
    }

}

@MainActor
private final class FakeDiscoveryAPI: DiscoveryAPI {
    let baseURL = "https://jellyfin.test"
    var requestedMixes: [String] = []
    var shouldFailMixes = false
    var shouldReturnEmptyMixes = false
    var shouldFailFavorites = false
    var shouldFailRecent = true
    var serverRecentTracks: [BaseItemDto] = []
    var audioMuseAvailable = true
    var shouldFailAudioMuseInfoAsNotFound = false
    var audioMuseInfoError: Error?
    var audioMuseTaskError: Error?
    var activeAudioMuseTask: AudioMuseTaskStatus?

    func fetchInstantMix(itemId: String, limit: Int) async throws -> [BaseItemDto] {
        requestedMixes.append(itemId)
        if shouldFailMixes { throw FakeError.unavailable }
        if shouldReturnEmptyMixes { return [] }
        return [audio(id: "mix-\(itemId)", artist: "Mix \(itemId)")]
    }

    func fetchFavoriteTracks(limit: Int) async throws -> [BaseItemDto] {
        if shouldFailFavorites { throw FakeError.unavailable }
        return [audio(id: "favorite-c", artist: "Artist C")]
    }

    func fetchRecentlyPlayedTracks(limit: Int) async throws -> [BaseItemDto] {
        if shouldFailRecent { throw FakeError.unavailable }
        return Array(serverRecentTracks.prefix(limit))
    }

    func fetchRandomTracks(limit: Int) async throws -> [BaseItemDto] {
        [audio(id: "random-d", artist: "Artist D")]
    }

    func fetchAudioMuseInfo() async throws -> AudioMusePluginInfo {
        if let audioMuseInfoError { throw audioMuseInfoError }
        if shouldFailAudioMuseInfoAsNotFound { throw JellyfinError.notFound }
        guard audioMuseAvailable else { throw JellyfinError.notFound }
        return AudioMusePluginInfo(version: "1", availableEndpoints: [])
    }

    func checkAudioMuseHealth() async throws -> Bool { audioMuseAvailable }
    func fetchActiveAudioMuseTask() async throws -> AudioMuseTaskStatus? {
        if let audioMuseTaskError { throw audioMuseTaskError }
        return activeAudioMuseTask
    }

    func audio(id: String, artist: String) -> BaseItemDto {
        BaseItemDto(
            Id: id,
            Name: id,
            Type: .Audio,
            RunTimeTicks: 10_000_000,
            Album: "Album",
            Artists: [artist],
            ArtistItems: [NameIdPair(Name: artist, Id: artist.lowercased())]
        )
    }
}

private actor FakeDiscoveryCandidateProvider: DiscoveryCandidateProviding {
    private var storedCandidates: [DiscoveryCandidate]

    init(candidates: [DiscoveryCandidate]) {
        storedCandidates = candidates
    }

    func setCandidates(_ candidates: [DiscoveryCandidate]) {
        storedCandidates = candidates
    }

    func discoveryCandidates(in scope: LibraryScope) -> [DiscoveryCandidate] {
        storedCandidates
    }

    func replace(with candidates: [DiscoveryCandidate]) {
        storedCandidates = candidates
    }
}

private enum FakeError: Error {
    case unavailable
}

/// Covers the shared action layer that backs both the AppleScript commands and
/// the App Intents surface.
struct AureliaActionTests {

    @Test func nameMatchingPrefersExactThenPrefixIgnoringCaseAndDiacritics() {
        let albums = [
            Album(id: "1", name: "Homogenic Remixes", artistName: "Björk", artistId: "b", year: nil, artworkURL: nil),
            Album(id: "2", name: "Homogenic", artistName: "Björk", artistId: "b", year: nil, artworkURL: nil),
            Album(id: "3", name: "Vespertine", artistName: "Björk", artistId: "b", year: nil, artworkURL: nil)
        ]

        // An exact match wins even when a prefix match comes first in the list.
        #expect(AureliaActions.match("Homogenic", in: albums, name: \.name)?.id == "2")
        // Prefixes still resolve when nothing matches exactly.
        #expect(AureliaActions.match("Homogenic Rem", in: albums, name: \.name)?.id == "1")
        // Case and diacritics are folded, and surrounding whitespace ignored.
        #expect(AureliaActions.match("  vespertine ", in: albums, name: \.name)?.id == "3")
        #expect(AureliaActions.match("Nothing Here", in: albums, name: \.name) == nil)
    }

    @Test func artistMatchingFoldsDiacritics() {
        let artists = [
            Artist(id: "b", name: "Björk", bio: nil, albumCount: 2, artworkURL: nil),
            Artist(id: "k", name: "Kraftwerk", bio: nil, albumCount: 9, artworkURL: nil)
        ]
        #expect(AureliaActions.match("bjork", in: artists, name: \.name)?.id == "b")
        #expect(AureliaActions.match("KRAFTWERK", in: artists, name: \.name)?.id == "k")
    }

    /// Every failure has to name itself — a silent no-op is what made the player
    /// look unreliable to out-of-process callers in the first place.
    @Test func outcomesReportFailuresExplicitly() {
        #expect(AureliaActions.Outcome.noTrack.message == "no track")
        #expect(AureliaActions.Outcome.notSignedIn.message == "not signed in")
        #expect(AureliaActions.Outcome.noMatch.message == "no match")
        #expect(AureliaActions.Outcome.empty.message == "nothing to play")
        #expect(AureliaActions.Outcome.ok("playing Homogenic").message == "playing Homogenic")
    }

    @Test func entitiesCarryTheLibraryNamesShortcutsDisplays() {
        let album = Album(
            id: "album",
            name: "Homogenic",
            artistName: "Björk",
            artistId: "b",
            year: 1997,
            artworkURL: nil
        )
        let artist = Artist(id: "b", name: "Björk", bio: nil, albumCount: 1, artworkURL: nil)
        let playlist = Playlist(
            id: "p",
            name: "Iceland",
            trackCount: 3,
            artworkURL: nil,
            dateCreated: nil
        )

        #expect(AlbumEntity(album).id == "album")
        #expect(AlbumEntity(album).name == "Homogenic")
        #expect(AlbumEntity(album).artistName == "Björk")
        #expect(ArtistEntity(artist).name == "Björk")
        #expect(PlaylistEntity(playlist).name == "Iceland")
    }

    /// The artist shuffle intent must not queue an unbounded library; the
    /// artist screen caps it and the action layer mirrors that.
    @Test func artistShuffleCapMatchesTheArtistScreen() {
        #expect(AureliaActions.artistShuffleLimit == 200)
    }

    /// Pressing Next must advance even with repeat-one on. Repeat-one governs
    /// what happens when a track ends by itself, which is handled elsewhere;
    /// conflating the two made the Next button silently restart the song.
    @Test func explicitNextAdvancesRegardlessOfRepeatOne() {
        // Mid-queue: every mode moves on.
        for mode in [PlayerManager.RepeatMode.off, .all, .one] {
            #expect(QueueAdvance.nextIndex(current: 0, count: 3, repeatMode: mode) == 1)
        }

        // At the end: repeat wraps, off stops.
        #expect(QueueAdvance.nextIndex(current: 2, count: 3, repeatMode: .all) == 0)
        #expect(QueueAdvance.nextIndex(current: 2, count: 3, repeatMode: .one) == 0)
        #expect(QueueAdvance.nextIndex(current: 2, count: 3, repeatMode: .off) == nil)

        // A single-track queue still repeats itself rather than stalling.
        #expect(QueueAdvance.nextIndex(current: 0, count: 1, repeatMode: .one) == 0)
        #expect(QueueAdvance.nextIndex(current: 0, count: 1, repeatMode: .off) == nil)

        #expect(QueueAdvance.nextIndex(current: 0, count: 0, repeatMode: .all) == nil)
    }

    /// Favourites refresh on their own now, so the item-type routing that used
    /// to come free with a full library sync has to be correct here instead.
    @Test func favoritesSnapshotRoutesServerItemsByType() {
        let items = [
            BaseItemDto(Id: "t", Name: "Jóga", Type: .Audio, RunTimeTicks: 10_000_000),
            BaseItemDto(Id: "al", Name: "Homogenic", Type: .MusicAlbum),
            BaseItemDto(Id: "ar", Name: "Björk", Type: .MusicArtist),
            // A favourited playlist has nowhere to go in this view.
            BaseItemDto(Id: "pl", Name: "Iceland", Type: .Playlist)
        ]

        let snapshot = FavoritesSnapshot.from(items: items, baseURL: "https://music.example")

        #expect(snapshot.tracks.map(\.id) == ["t"])
        #expect(snapshot.albums.map(\.id) == ["al"])
        #expect(snapshot.artists.map(\.id) == ["ar"])
        #expect(FavoritesSnapshot.from(items: [], baseURL: "https://music.example").isEmpty)
    }

    /// The catalog is what tells browsing which containers still have something
    /// playable, so the mapping from downloaded tracks upward has to hold.
    /// Sync watermarks go back to the server as `MinDateLastSaved` and are
    /// compared against its own timestamps, so they have to be in the server's
    /// terms. A device running fast would otherwise skip every change made in
    /// the difference — permanently, until the daily reconciliation.
    @Test func serverClockOffsetComesFromTheDateHeader() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let header = "Thu, 14 Nov 2023 22:13:20 GMT" // the same instant

        let offset = try? #require(
            JellyfinService.clockOffset(fromDateHeader: header, now: now)
        )
        #expect(abs((offset ?? 999) - 0) < 1)

        // A server running two minutes ahead.
        let ahead = JellyfinService.clockOffset(
            fromDateHeader: "Thu, 14 Nov 2023 22:15:20 GMT",
            now: now
        )
        #expect(abs((ahead ?? 0) - 120) < 1)

        // Unparseable leaves the offset alone: a wrong one is worse than none.
        #expect(JellyfinService.clockOffset(fromDateHeader: "not a date", now: now) == nil)
        #expect(JellyfinService.clockOffset(fromDateHeader: "", now: now) == nil)
    }

    /// `/Artists` returns an entity for every `feat.`, `vs.` and `A/B` credit
    /// string on a track, which swamps browsing. Only album artists are listed
    /// — but the rest stay in the catalog, or a track's "Go to Artist" and any
    /// search for a guest would break.
    @Test func browsingListsAlbumArtistsWithoutLosingTheRest() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Library.sqlite")
        let repository = try LibraryRepository(databaseURL: databaseURL)
        let scope = try #require(LibraryScope(baseURL: "https://music.example", userID: "listener"))

        let headline = Artist(id: "headline", name: "Access to Arasaka", bio: nil, albumCount: 1, artworkURL: nil)
        let guest = Artist(
            id: "guest", name: "Access to Arasaka feat. Jamie Blacker",
            bio: nil, albumCount: 0, artworkURL: nil
        )

        try await repository.replaceCompleteLibrary(
            LibraryCatalog(
                albums: [], artists: [headline, guest], tracks: [],
                playlists: [], genres: [], playlistEntries: []
            ),
            in: scope
        )

        // Nothing recorded yet: an unfiltered list beats an empty one.
        let beforeSync = try await repository.librarySnapshot(in: scope).artists.map(\.id)
        #expect(Set(beforeSync) == ["headline", "guest"])

        try await repository.replaceAlbumArtists(["headline"], in: scope)

        let browsable = try await repository.librarySnapshot(in: scope).artists.map(\.id)
        #expect(browsable == ["headline"])

        // Still findable, and still resolvable by ID for its own page.
        let hits = try await repository.search(
            "Jamie", filter: .artists, in: scope, limit: 20
        )
        #expect(hits.isEmpty)
        #expect(try await repository.albums(forArtist: guest.id, in: scope).isEmpty)
    }

    /// Jellyfin's own normalisation, so the local catalog and the server agree
    /// on which names are the same artist.
    @Test func cleanNameMatchesJellyfinNormalisation() {
        #expect(LibraryRepository.cleanName(":Wumpscut:") == ":wumpscut:")
        #expect(LibraryRepository.cleanName("Björk") == "bjork")
        #expect(LibraryRepository.cleanName("  Air  ") == "air")
        // Not a case difference — a different string, and the server treats it
        // as a different artist too.
        #expect(LibraryRepository.cleanName("Wumpscut") != LibraryRepository.cleanName(":Wumpscut:"))
    }

    /// Jellyfin resolves an item's artist IDs with an exact-name lookup and
    /// drops what it cannot match, so albums tagged `:wumpscut:` under an
    /// artist named `:Wumpscut:` arrive with no artist at all — while the same
    /// server lists them happily when asked by that artist's ID.
    @Test func syncLinksArtistsThatTheServerLeftUnresolved() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Library.sqlite")
        let repository = try LibraryRepository(databaseURL: databaseURL)
        let scope = try #require(LibraryScope(baseURL: "https://music.example", userID: "listener"))

        let artist = Artist(id: "artist", name: ":Wumpscut:", bio: nil, albumCount: 2, artworkURL: nil)
        let other = Artist(id: "other", name: "Wumpscut", bio: nil, albumCount: 1, artworkURL: nil)
        // Arrived with no artist ID, exactly as the server sends it.
        let unresolved = Album(
            id: "unresolved", name: "Bone Peeler", artistName: ":wumpscut:",
            artistId: nil, year: 2006, artworkURL: nil, genreIDs: []
        )
        // Arrived resolved, and must be left alone.
        let resolved = Album(
            id: "resolved", name: "Boeses Junges Fleisch", artistName: ":Wumpscut:",
            artistId: artist.id, year: 2004, artworkURL: nil, genreIDs: []
        )
        // A genuinely different name, which the server also keeps separate.
        let unrelated = Album(
            id: "unrelated", name: "Something Else", artistName: "Wumpscut",
            artistId: nil, year: 1999, artworkURL: nil, genreIDs: []
        )
        let track = Track(
            id: "track", name: "Crown Of Thorns", artistName: ":wumpscut:",
            albumName: unresolved.name, duration: 200, artworkURL: nil,
            indexNumber: 1, albumId: unresolved.id, artistId: nil,
            artistIDs: nil, genreIDs: []
        )

        try await repository.replaceCompleteLibrary(
            LibraryCatalog(
                albums: [unresolved, resolved, unrelated],
                artists: [artist, other],
                tracks: [track],
                playlists: [], genres: [], playlistEntries: []
            ),
            in: scope
        )

        #expect(try await repository.albums(forArtist: artist.id, in: scope).map(\.id) == ["resolved"])

        // Three: the album and track tagged `:wumpscut:`, plus the one tagged
        // `Wumpscut`, which links to its own separate artist by the same rule.
        let linked = try await repository.linkArtistsByName(in: scope)
        #expect(linked == 3)

        let albums = try await repository.albums(forArtist: artist.id, in: scope).map(\.id)
        #expect(Set(albums) == ["unresolved", "resolved"])
        // The differently-named album stays with its own artist.
        #expect(try await repository.albums(forArtist: other.id, in: scope).map(\.id) == ["unrelated"])
        // Tracks matter as much as albums — Shuffle reads them.
        #expect(try await repository.tracks(forArtist: artist.id, in: scope).map(\.id) == ["track"])

        // Idempotent: a second sync must not relink what is already linked.
        #expect(try await repository.linkArtistsByName(in: scope) == 0)
    }

    @Test func offlineContainersMapDownloadedTracksToAlbumsArtistsAndPlaylists() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Library.sqlite")
        let repository = try LibraryRepository(databaseURL: databaseURL)
        let scope = try #require(LibraryScope(baseURL: "https://music.example", userID: "listener"))

        let albumArtist = Artist(id: "va", name: "Various Artists", bio: nil, albumCount: 1, artworkURL: nil)
        let trackArtist = Artist(id: "bjork", name: "Björk", bio: nil, albumCount: 0, artworkURL: nil)
        let compilation = Album(
            id: "comp",
            name: "Iceland Airwaves",
            artistName: albumArtist.name,
            artistId: albumArtist.id,
            year: 2001,
            artworkURL: nil,
            genreIDs: []
        )
        let untouched = Album(
            id: "other",
            name: "Vespertine",
            artistName: trackArtist.name,
            artistId: trackArtist.id,
            year: 2001,
            artworkURL: nil,
            genreIDs: []
        )
        func track(_ id: String, album: Album) -> Track {
            Track(
                id: id,
                name: id,
                artistName: trackArtist.name,
                albumName: album.name,
                duration: 200,
                artworkURL: nil,
                indexNumber: 1,
                albumId: album.id,
                artistId: trackArtist.id,
                artistIDs: [trackArtist.id],
                genreIDs: []
            )
        }
        let downloaded = track("downloaded", album: compilation)
        let streaming = track("streaming", album: untouched)
        let saved = Playlist(id: "saved", name: "Saved", trackCount: 1, artworkURL: nil, dateCreated: nil)
        let empty = Playlist(id: "empty", name: "Nothing local", trackCount: 1, artworkURL: nil, dateCreated: nil)

        try await repository.replaceCompleteLibrary(
            LibraryCatalog(
                albums: [compilation, untouched],
                artists: [albumArtist, trackArtist],
                tracks: [downloaded, streaming],
                playlists: [saved, empty],
                genres: [],
                playlistEntries: [
                    LibraryPlaylistEntry(playlistID: saved.id, track: downloaded, position: 0),
                    LibraryPlaylistEntry(playlistID: empty.id, track: streaming, position: 0)
                ]
            ),
            in: scope
        )

        let containers = try await repository.offlineContainers(
            forTrackIDs: [downloaded.id],
            in: scope
        )

        #expect(containers.albumIDs == [compilation.id])
        #expect(containers.playlistIDs == [saved.id])
        // The album artist is credited even though no track names them, which
        // is exactly the compilation case a download record cannot express.
        #expect(containers.artistIDs == [trackArtist.id, albumArtist.id])

        #expect(try await repository.offlineContainers(forTrackIDs: [], in: scope) == OfflineContainerIDs())
    }

    /// Fetching on the final song left Up Next empty at exactly the moment it
    /// was meant to show what comes next, with no time for AudioMuse to answer.
    @Test func autoplayPrimesBeforeTheQueueRunsOut() {
        // Four songs still to come is too early to fill the list with guesses.
        #expect(AutoplayPriming.shouldPrime(currentIndex: 7, queueCount: 12) == false)
        #expect(AutoplayPriming.shouldPrime(currentIndex: 8, queueCount: 12) == true)
        #expect(AutoplayPriming.shouldPrime(currentIndex: 11, queueCount: 12) == true)
        // A single tapped song has nothing after it at all.
        #expect(AutoplayPriming.shouldPrime(currentIndex: 0, queueCount: 1) == true)

        #expect(AutoplayPriming.shouldPrime(currentIndex: 0, queueCount: 0) == false)
        #expect(AutoplayPriming.shouldPrime(currentIndex: -1, queueCount: 5) == false)
        #expect(AutoplayPriming.shouldPrime(currentIndex: 5, queueCount: 5) == false)
    }

    /// A continuation adds one batch, not everything the mix returned. More is
    /// asked for than a batch needs, because songs already queued get dropped.
    @Test func autoplayBatchIsCappedAndDeduplicated() {
        func track(_ id: String) -> Track {
            Track(
                id: id,
                name: id,
                artistName: "Artist",
                albumName: "Album",
                duration: 200,
                artworkURL: nil
            )
        }
        let mix = (0..<AutoplayPriming.requestSize).map { track("mix-\($0)") }

        let full = AutoplayPriming.batch(from: mix, excluding: [])
        #expect(full.count == AutoplayPriming.batchSize)
        #expect(full.first?.id == "mix-0")

        // Over-requesting is what absorbs the songs the queue already holds, so
        // a batch still fills up after they are dropped.
        let alreadyQueued = Set((0..<8).map { "mix-\($0)" })
        let trimmed = AutoplayPriming.batch(from: mix, excluding: alreadyQueued)
        #expect(trimmed.count == AutoplayPriming.batchSize)
        #expect(trimmed.allSatisfy { !alreadyQueued.contains($0.id) })

        // A mix that repeats itself must not pad the batch with duplicates.
        let repetitive = [track("a"), track("a"), track("b")]
        #expect(AutoplayPriming.batch(from: repetitive, excluding: []).map(\.id) == ["a", "b"])
        #expect(AutoplayPriming.batch(from: [], excluding: []).isEmpty)
    }

    /// A suggestion stops being a suggestion once it plays — the listener is in
    /// it now, so the run reverts to being the queue rather than having the
    /// marker creep down the list one song at a time.
    @Test func autoplayRunStopsBeingMarkedOnceReached() {
        #expect(AutoplayPriming.startIndexStillAhead(currentIndex: 8, autoplayStartIndex: 10) == 10)
        #expect(AutoplayPriming.startIndexStillAhead(currentIndex: 10, autoplayStartIndex: 10) == nil)
        #expect(AutoplayPriming.startIndexStillAhead(currentIndex: 14, autoplayStartIndex: 10) == nil)
        #expect(AutoplayPriming.startIndexStillAhead(currentIndex: 3, autoplayStartIndex: nil) == nil)
    }

    /// Reading AudioMuse has three rules that are easy to get wrong, and the
    /// second copy of this logic in Settings got all three wrong before they
    /// were pulled back into one place.
    @Test @MainActor func audioMuseReadingKeepsAConfirmedPluginConfirmed() async {
        let api = FakeDiscoveryAPI()
        api.audioMuseInfoError = JellyfinError.notFound

        // Never seen: the only honest way to report it missing.
        let firstEver = await AudioMuseStatusProbe.read(from: api, presenceAlreadyConfirmed: false)
        #expect(firstEver.availability == .notInstalled)
        #expect(firstEver.confirmedPresence == false)

        // Seen before: one failed request cannot uninstall a plugin, so the
        // caller is told nothing rather than told something false.
        let afterConfirmed = await AudioMuseStatusProbe.read(from: api, presenceAlreadyConfirmed: true)
        #expect(afterConfirmed.availability == nil)
        #expect(afterConfirmed.confirmedPresence == true)
    }

    @Test @MainActor func audioMuseReadingToleratesAFailingTaskEndpoint() async {
        let api = FakeDiscoveryAPI()
        // The plugin answers for itself, but its task endpoint does not. Task
        // status is informative only, so this is still a working plugin.
        api.audioMuseTaskError = JellyfinError.notFound

        let reading = await AudioMuseStatusProbe.read(from: api, presenceAlreadyConfirmed: false)
        #expect(reading.availability == .ready(version: "1"))
        #expect(reading.confirmedPresence == true)
    }

    @Test @MainActor func audioMuseReadingTreatsCancellationAsNoAnswer() async {
        let api = FakeDiscoveryAPI()
        api.audioMuseInfoError = CancellationError()

        // Leaving the screen mid-request must not be reported as an outage.
        let reading = await AudioMuseStatusProbe.read(from: api, presenceAlreadyConfirmed: true)
        #expect(reading.availability == nil)
        #expect(reading.confirmedPresence == true)
    }

    @Test @MainActor func audioMuseReadingReportsAnActiveAnalysis() async throws {
        let api = FakeDiscoveryAPI()
        api.activeAudioMuseTask = try JSONDecoder().decode(
            AudioMuseTaskStatus.self,
            from: Data(
                #"{"task_id":"t","task_type":"library-analysis","status":"running","progress":0.5,"message":"Analyzing"}"#.utf8
            )
        )

        let reading = await AudioMuseStatusProbe.read(from: api, presenceAlreadyConfirmed: false)
        guard case .analyzing(let task) = reading.availability else {
            Issue.record("expected an analysis in progress")
            return
        }
        #expect(task.message == "Analyzing")
        #expect(reading.confirmedPresence == true)
    }

    /// Continuation is on unless the listener turned it off. The stored value
    /// has to be read as an object, since `UserDefaults.bool(forKey:)` reports
    /// "never chosen" and "explicitly off" identically and would quietly pin
    /// everyone to the old default.
    @Test func autoplayContinuationDefaultsOnUntilTurnedOff() {
        #expect(AutoplayPreference.isEnabled(storedValue: nil) == true)
        #expect(AutoplayPreference.isEnabled(storedValue: false) == false)
        #expect(AutoplayPreference.isEnabled(storedValue: true) == true)
        // A value of another type is not a choice either.
        #expect(AutoplayPreference.isEnabled(storedValue: "yes") == true)
    }

    /// The compact player fills its page: artwork takes whatever the rest of
    /// the column leaves, so the queue starts on the next screen rather than
    /// peeking out from a band of dead space.
    @Test func compactArtworkTakesWhatTheColumnLeaves() {
        let contentWidth: CGFloat = 353

        // Height is the binding constraint on a phone-shaped page.
        #expect(
            NowPlayingLayout.compactArtworkSize(
                contentWidth: contentWidth,
                availableHeight: 300
            ) == 300
        )
        // A tall page runs out of width first, and the remainder is what the
        // surrounding spacers turn into centring.
        #expect(
            NowPlayingLayout.compactArtworkSize(
                contentWidth: contentWidth,
                availableHeight: 900
            ) == contentWidth
        )
        // A column too short to give the artwork anything keeps it recognisable
        // and lets the content scroll instead.
        #expect(
            NowPlayingLayout.compactArtworkSize(
                contentWidth: contentWidth,
                availableHeight: -40
            ) == NowPlayingLayout.compactMinimumArtworkSize
        )
        // The floor never wins against a genuinely narrow column.
        #expect(
            NowPlayingLayout.compactArtworkSize(contentWidth: 100, availableHeight: -40) == 100
        )
        #expect(NowPlayingLayout.compactArtworkSize(contentWidth: 0, availableHeight: 400) == 0)
    }

    @Test func offlineCatalogAnswersPerSubject() {
        let catalog = OfflineCatalog(
            trackIDs: ["t1"],
            containers: OfflineContainerIDs(
                albumIDs: ["al1"],
                artistIDs: ["ar1"],
                playlistIDs: ["pl1"]
            )
        )

        #expect(catalog.hasLocalCopy(of: .track("t1")))
        #expect(!catalog.hasLocalCopy(of: .track("t2")))
        #expect(catalog.hasLocalCopy(of: .album("al1")))
        #expect(!catalog.hasLocalCopy(of: .album("al2")))
        #expect(catalog.hasLocalCopy(of: .artist("ar1")))
        #expect(catalog.hasLocalCopy(of: .playlist("pl1")))
        // An ID that names nothing local must not be mistaken for another kind.
        #expect(!catalog.hasLocalCopy(of: .artist("al1")))
        #expect(!OfflineCatalog().hasLocalCopy(of: .track("t1")))
    }

    /// Firsthand evidence — the socket opening, a request failing — settles
    /// reachability outright, with no probe involved.
    @MainActor
    @Test func networkMonitorTrustsFirsthandEvents() {
        let monitor = NetworkMonitor(pathMonitor: nil, probe: OfflineProbeStub(result: true).run)
        // Optimistic until something says otherwise, so a cold launch does not
        // flash the whole library as unavailable.
        #expect(monitor.isOffline == false)

        monitor.noteServerUnreachable()
        #expect(monitor.isOffline == true)
        monitor.noteServerReachable()
        #expect(monitor.isOffline == false)
    }

    /// A dropped socket is only secondhand evidence: a proxy that refuses to
    /// pass upgrades breaks the socket while leaving HTTP intact, so a drop is
    /// confirmed before the whole library gets marked unavailable.
    @MainActor
    @Test func networkMonitorConfirmsADroppedSocketBeforeMarkingContent() async {
        let serverStillUp = NetworkMonitor(
            pathMonitor: nil,
            probe: OfflineProbeStub(result: true).run
        )
        serverStillUp.noteServerConnectionLost()
        await serverStillUp.probeServer()
        #expect(serverStillUp.isOffline == false)

        let serverGone = NetworkMonitor(
            pathMonitor: nil,
            probe: OfflineProbeStub(result: false).run
        )
        serverGone.noteServerConnectionLost()
        await serverGone.probeServer()
        #expect(serverGone.isOffline == true)
    }

    /// Online, nothing is marked — a library that is mostly not downloaded
    /// would otherwise read as mostly broken.
    @MainActor
    @Test func offlineAvailabilityOnlyMarksContentWhileOffline() async {
        let monitor = NetworkMonitor(pathMonitor: nil, probe: OfflineProbeStub(result: false).run)
        let availability = OfflineAvailability(monitor: monitor)
        #expect(availability.isUnavailable(.album("anything")) == false)

        availability.start()
        await monitor.probeServer()
        #expect(availability.isUnavailable(.album("anything")) == true)
    }
}

/// Keeps the probe result out of the closure's capture list so the stub can be
/// handed to `NetworkMonitor` as a plain function reference.
@MainActor
private final class OfflineProbeStub {
    let result: Bool
    init(result: Bool) { self.result = result }
    func run() async -> Bool { result }
}
