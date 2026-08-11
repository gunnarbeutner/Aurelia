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
@testable import JellyAmp

struct JellyAmpTests {

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
    }

    @Test @MainActor func discoveryFallsBackWhenFavoriteSeedsFail() async {
        let api = FakeDiscoveryAPI()
        api.shouldFailFavorites = true
        let viewModel = DiscoveryViewModel(api: api, recentTracksProvider: { [] })

        await viewModel.refresh()

        #expect(viewModel.shelves.map(\.seed.id) == ["random-d"])
        #expect(viewModel.errorMessage == nil)
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

        await viewModel.activate()

        #expect(viewModel.shelves.first?.seed.id == "recent-b")
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
    }

    @Test @MainActor func signedBuildCanAccessKeychain() {
        let key = "signing-verification-\(UUID().uuidString)"
        let value = UUID().uuidString
        defer { KeychainService.shared.remove(for: key) }

        KeychainService.shared.store(value, for: key)

        #expect(KeychainService.shared.retrieve(for: key) == value)
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

}

@MainActor
private final class FakeDiscoveryAPI: DiscoveryAPI {
    let baseURL = "https://jellyfin.test"
    var requestedMixes: [String] = []
    var shouldFailFavorites = false

    func fetchInstantMix(itemId: String, limit: Int) async throws -> [BaseItemDto] {
        requestedMixes.append(itemId)
        return [audio(id: "mix-\(itemId)", artist: "Mix \(itemId)")]
    }

    func fetchFavoriteTracks(limit: Int) async throws -> [BaseItemDto] {
        if shouldFailFavorites { throw FakeError.unavailable }
        return [audio(id: "favorite-c", artist: "Artist C")]
    }

    func fetchRandomTracks(limit: Int) async throws -> [BaseItemDto] {
        [audio(id: "random-d", artist: "Artist D")]
    }

    func fetchAudioMuseInfo() async throws -> AudioMusePluginInfo {
        AudioMusePluginInfo(version: "1", availableEndpoints: [])
    }

    func checkAudioMuseHealth() async throws -> Bool { true }
    func fetchActiveAudioMuseTask() async throws -> AudioMuseTaskStatus? { nil }

    private func audio(id: String, artist: String) -> BaseItemDto {
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
