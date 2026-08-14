//
//  DiscoveryAPI.swift
//  Aurelia
//
//  Typed API surface used by Discover and Instant Mix playback.
//

import Foundation

protocol DiscoveryAPI {
    var baseURL: String { get }

    func fetchInstantMix(itemId: String, limit: Int) async throws -> [BaseItemDto]
    func fetchRecentlyPlayedTracks(limit: Int) async throws -> [BaseItemDto]
    func fetchRandomTracks(limit: Int) async throws -> [BaseItemDto]
    func fetchAudioMuseInfo() async throws -> AudioMusePluginInfo
    func checkAudioMuseHealth() async throws -> Bool
    func fetchActiveAudioMuseTask() async throws -> AudioMuseTaskStatus?
}

nonisolated struct AudioMusePluginInfo: Decodable, Equatable {
    let version: String
    let availableEndpoints: [String]

    enum CodingKeys: String, CodingKey {
        case version = "Version"
        case availableEndpoints = "AvailableEndpoints"
    }
}

nonisolated struct AudioMuseTaskStatus: Decodable, Equatable {
    let taskId: String?
    let taskType: String?
    let status: String?
    let progress: Double?
    let runningTimeSeconds: Double?
    let message: String?

    var isActive: Bool {
        guard let status = status?.lowercased() else { return true }
        return !["completed", "complete", "failed", "cancelled", "canceled"].contains(status)
    }

    var progressFraction: Double? {
        guard let progress else { return nil }
        let fraction = progress > 1 ? progress / 100 : progress
        return min(max(fraction, 0), 1)
    }

    enum CodingKeys: String, CodingKey {
        case taskId = "task_id"
        case taskType = "task_type"
        case status
        case progress
        case runningTimeSeconds = "running_time_seconds"
        case details
        case message
    }

    private struct Details: Decodable {
        let message: String?
        let statusMessage: String?

        enum CodingKeys: String, CodingKey {
            case message
            case statusMessage = "status_message"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        taskId = try container.decodeIfPresent(String.self, forKey: .taskId)
        taskType = try container.decodeIfPresent(String.self, forKey: .taskType)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        progress = Self.decodeFlexibleDouble(from: container, forKey: .progress)
        runningTimeSeconds = Self.decodeFlexibleDouble(from: container, forKey: .runningTimeSeconds)
        let details = try? container.decode(Details.self, forKey: .details)
        message = (try? container.decode(String.self, forKey: .message))
            ?? details?.message
            ?? details?.statusMessage
    }

    private static func decodeFlexibleDouble(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Double? {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(String.self, forKey: key) {
            return Double(value)
        }
        return nil
    }
}

enum AudioMuseAvailability: Equatable {
    case checking
    case analyzing(AudioMuseTaskStatus)
    case ready(version: String)
    case unavailable
    case notInstalled
}

extension JellyfinService: DiscoveryAPI {}

#if DEBUG
/// Network-free recommendations used only by the Now Playing UI regression test.
struct PlayerLayoutDiscoveryAPI: DiscoveryAPI {
    let baseURL = "https://ui-test.invalid"

    func fetchInstantMix(itemId: String, limit: Int) async throws -> [BaseItemDto] {
        [
            audio(
                id: "ui-layout-track",
                name: "The Age Of Love (Extended Live Version) (Live)"
            ),
            audio(id: "ui-layout-next", name: "Next Test Track"),
            // A mix only reaches a shelf if it crosses an artist boundary.
            audio(
                id: "ui-layout-after-next",
                name: "After Delete Test Track",
                artist: "Second Layout Artist",
                artistID: "ui-layout-artist-2"
            )
        ]
    }

    func fetchRecentlyPlayedTracks(limit: Int) async throws -> [BaseItemDto] {
        [audio(id: "ui-layout-seed", name: "Layout Seed")]
    }
    func fetchRandomTracks(limit: Int) async throws -> [BaseItemDto] { [] }
    // Daily Mixes are an AudioMuse feature, so the fixture has to claim the
    // plugin is installed for the mixes shelf to exist at all.
    func fetchAudioMuseInfo() async throws -> AudioMusePluginInfo {
        AudioMusePluginInfo(version: "ui-test", availableEndpoints: [])
    }
    func checkAudioMuseHealth() async throws -> Bool { true }
    func fetchActiveAudioMuseTask() async throws -> AudioMuseTaskStatus? { nil }

    private func audio(
        id: String,
        name: String,
        artist: String = "Layout Artist",
        artistID: String = "ui-layout-artist"
    ) -> BaseItemDto {
        BaseItemDto(
            Id: id,
            Name: name,
            Type: .Audio,
            RunTimeTicks: 2_400_000_000,
            Album: "Layout Album",
            AlbumArtist: artist,
            Artists: [artist],
            AlbumId: "ui-layout-album",
            AlbumPrimaryImageTag: "ui-test",
            ArtistItems: [NameIdPair(Name: artist, Id: artistID)]
        )
    }
}

/// Mix shelves are seeded from the local library, so the UI test needs one
/// candidate to stand in for it.
struct PlayerLayoutDiscoveryCandidates: DiscoveryCandidateProviding {
    static let seed = Track(
        id: "ui-layout-mix",
        name: "Layout Mix Seed",
        artistName: "Layout Artist",
        albumName: "Layout Album",
        duration: 240,
        artworkURL: nil,
        albumId: "ui-layout-album",
        artistId: "ui-layout-artist"
    )

    func discoveryCandidates(in scope: LibraryScope) async -> [DiscoveryCandidate] {
        [DiscoveryCandidate(track: Self.seed, lastPlayedAt: nil, playCount: 1, isFavorite: false)]
    }
}
#endif
