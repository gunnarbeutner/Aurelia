//
//  JellyAmpTests.swift
//  JellyAmpTests
//
//  Created by Grafton on 10/17/25.
//

import Testing
import Foundation
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
