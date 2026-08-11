//
//  JellyAmpTests.swift
//  JellyAmpTests
//
//  Created by Grafton on 10/17/25.
//

import Testing
import Foundation
import Combine
import UIKit
import SwiftUI
@testable import JellyAmp

struct JellyAmpTests {

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

        #expect(viewModel.shelves.map(\.seed.id) == ["recent-a", "recent-b", "favorite-c"])
        #expect(api.requestedMixes.prefix(2) == ["recent-a", "recent-b"])
        #expect(viewModel.recentTracks.map(\.id) == ["recent-a", "recent-a2", "recent-b"])
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

    @Test @MainActor func imageMemoryCacheHitsAreSynchronous() {
        let url = URL(string: "https://jellyamp.test/artwork/\(UUID().uuidString)")!
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
            artworkURL: "https://jellyamp.test/album.jpg",
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
                artworkURL: "https://jellyamp.test/album.jpg"
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

    @Test @MainActor func nowPlayingArtworkRemainsCenteredAtIPhoneWidths() {
        for screenWidth in [320.0, 375.0, 393.0, 430.0] {
            let contentWidth = NowPlayingLayout.contentWidth(for: screenWidth)
            let artworkWidth = NowPlayingLayout.artworkSize(for: screenWidth)
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
        #expect(JellyAmpShortcuts.playPause.key == .space)
        #expect(JellyAmpShortcuts.playPause.modifiers.isEmpty)
        #expect(JellyAmpShortcuts.previousTrack.key == .leftArrow)
        #expect(JellyAmpShortcuts.previousTrack.modifiers.isEmpty)
        #expect(JellyAmpShortcuts.nextTrack.key == .rightArrow)
        #expect(JellyAmpShortcuts.nextTrack.modifiers.isEmpty)
        #expect(JellyAmpShortcuts.seekBackward.modifiers == [.option, .command])
        #expect(JellyAmpShortcuts.seekForward.modifiers == [.option, .command])
        #expect(JellyAmpShortcuts.focusSearch.key == "f")
        #expect(JellyAmpShortcuts.focusSearch.modifiers == .command)
        #expect(JellyAmpShortcuts.tab(5).key == "5")
        #expect(JellyAmpShortcuts.tab(5).modifiers == .command)
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

        #expect(alphabetical == [
            LibraryScrollIndexEntry(label: "#", targetID: "numeric"),
            LibraryScrollIndexEntry(label: "A", targetID: "alpha"),
            LibraryScrollIndexEntry(label: "B", targetID: "beta")
        ])
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
