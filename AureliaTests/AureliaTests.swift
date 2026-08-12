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

    @Test @MainActor func discoveryPrefersRecentTracksAndDistinctArtists() async {
        let recentA = Track(id: "recent-a", name: "A", artistName: "Artist A", albumName: "One", duration: 1, artworkURL: nil, artistId: "artist-a")
        let duplicateArtist = Track(id: "recent-a2", name: "A2", artistName: "Artist A", albumName: "Two", duration: 1, artworkURL: nil, artistId: "artist-a")
        let recentB = Track(id: "recent-b", name: "B", artistName: "Artist B", albumName: "Three", duration: 1, artworkURL: nil, artistId: "artist-b")
        let api = FakeDiscoveryAPI()
        let viewModel = DiscoveryViewModel(api: api) { [recentA, duplicateArtist, recentB] }

        await viewModel.refresh()

        #expect(viewModel.shelves.map(\.seed.id) == ["recent-a", "recent-b", "favorite-c", "random-d"])
        #expect(api.requestedMixes.prefix(2) == ["recent-a", "recent-b"])
        #expect(viewModel.recentTracks.map(\.id) == ["recent-a", "recent-a2", "recent-b"])
    }

    @Test @MainActor func discoveryBuildsUpToMaximumMixShelves() async {
        let recent = (0..<8).map { index in
            Track(
                id: "recent-\(index)",
                name: "Recent \(index)",
                artistName: "Artist \(index)",
                albumName: "Album \(index)",
                duration: 1,
                artworkURL: nil,
                artistId: "artist-\(index)"
            )
        }
        let api = FakeDiscoveryAPI()
        let viewModel = DiscoveryViewModel(api: api, recentTracksProvider: { recent })

        await viewModel.refresh()

        #expect(viewModel.shelves.count == DiscoveryViewModel.maximumMixShelfCount)
        #expect(viewModel.shelves.map(\.seed.id) == [
            "recent-0", "recent-1", "recent-2", "recent-3", "recent-4",
            "recent-5", "recent-6", "recent-7", "favorite-c", "random-d"
        ])
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
        #expect(api.requestedMixes.first == "server")
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

    @Test @MainActor func discoveryFallsBackWhenFavoriteSeedsFail() async {
        let api = FakeDiscoveryAPI()
        api.shouldFailFavorites = true
        let viewModel = DiscoveryViewModel(api: api, recentTracksProvider: { [] })

        await viewModel.refresh()

        #expect(viewModel.shelves.map(\.seed.id) == ["random-d"])
        #expect(viewModel.errorMessage == nil)
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
        #expect(viewModel.errorMessage != nil)
    }

    @Test @MainActor func discoveryOffersStartListeningFallbackWithoutHistory() async {
        let api = FakeDiscoveryAPI()
        api.shouldFailMixes = true
        let viewModel = DiscoveryViewModel(api: api, recentTracksProvider: { [] })

        await viewModel.refresh()

        #expect(viewModel.shelves.isEmpty)
        #expect(viewModel.recentTracks.isEmpty)
        #expect(viewModel.fallbackTracks.map(\.id) == ["favorite-c", "random-d"])
    }

    @Test @MainActor func discoveryRetainsExistingMixesWhenEveryRefreshMixFails() async {
        var recent = [
            Track(
                id: "recent-a",
                name: "Recent A",
                artistName: "Artist A",
                albumName: "Album A",
                duration: 1,
                artworkURL: nil,
                artistId: "artist-a"
            )
        ]
        let api = FakeDiscoveryAPI()
        let viewModel = DiscoveryViewModel(api: api, recentTracksProvider: { recent })

        await viewModel.refresh()
        let originalShelves = viewModel.shelves
        recent = [
            Track(
                id: "recent-b",
                name: "Recent B",
                artistName: "Artist B",
                albumName: "Album B",
                duration: 1,
                artworkURL: nil,
                artistId: "artist-b"
            )
        ]
        api.shouldFailMixes = true

        await viewModel.refresh()

        #expect(viewModel.shelves == originalShelves)
        #expect(viewModel.recentTracks.map(\.id) == ["recent-b"])
        #expect(viewModel.errorMessage?.contains("Showing the previous mixes") == true)
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
        #expect(viewModel.errorMessage == "Instant Mixes are temporarily unavailable.")
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

    @Test @MainActor func discoveryStagesAutomaticRefreshUntilNextActivation() async {
        var recent = [
            Track(
                id: "recent-a",
                name: "Recent A",
                artistName: "Artist A",
                albumName: "Album A",
                duration: 1,
                artworkURL: nil,
                artistId: "artist-a"
            )
        ]
        let api = FakeDiscoveryAPI()
        let viewModel = DiscoveryViewModel(api: api, recentTracksProvider: { recent })

        await viewModel.refresh()
        #expect(viewModel.shelves.first?.seed.id == "recent-a")
        #expect(viewModel.recentTracks.map(\.id) == ["recent-a"])

        recent = [
            Track(
                id: "recent-b",
                name: "Recent B",
                artistName: "Artist B",
                albumName: "Album B",
                duration: 1,
                artworkURL: nil,
                artistId: "artist-b"
            )
        ]
        await viewModel.loadIfNeeded(publishResult: false)

        #expect(viewModel.shelves.first?.seed.id == "recent-a")
        #expect(viewModel.recentTracks.map(\.id) == ["recent-a"])

        await viewModel.activate()

        #expect(viewModel.shelves.first?.seed.id == "recent-b")
        #expect(viewModel.recentTracks.map(\.id) == ["recent-b"])
    }

    @Test @MainActor func discoveryExplicitRefreshPublishesStagedChangesImmediately() async {
        var recent = [
            Track(
                id: "recent-a",
                name: "Recent A",
                artistName: "Artist A",
                albumName: "Album A",
                duration: 1,
                artworkURL: nil,
                artistId: "artist-a"
            )
        ]
        let api = FakeDiscoveryAPI()
        let viewModel = DiscoveryViewModel(api: api, recentTracksProvider: { recent })

        await viewModel.refresh()
        recent = [
            Track(
                id: "recent-b",
                name: "Recent B",
                artistName: "Artist B",
                albumName: "Album B",
                duration: 1,
                artworkURL: nil,
                artistId: "artist-b"
            )
        ]
        await viewModel.loadIfNeeded(publishResult: false)
        #expect(viewModel.shelves.first?.seed.id == "recent-a")

        await viewModel.refresh()

        #expect(viewModel.shelves.first?.seed.id == "recent-b")
        #expect(viewModel.recentTracks.map(\.id) == ["recent-b"])
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
        AudioMusePluginInfo(version: "1", availableEndpoints: [])
    }

    func checkAudioMuseHealth() async throws -> Bool { true }
    func fetchActiveAudioMuseTask() async throws -> AudioMuseTaskStatus? { nil }

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
}
