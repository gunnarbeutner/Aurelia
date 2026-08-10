//
//  DiscoveryAPI.swift
//  JellyAmp
//
//  Typed API surface used by Discover and Instant Mix playback.
//

import Foundation

protocol DiscoveryAPI {
    var baseURL: String { get }

    func fetchInstantMix(itemId: String, limit: Int) async throws -> [BaseItemDto]
    func fetchFavoriteTracks(limit: Int) async throws -> [BaseItemDto]
    func fetchRandomTracks(limit: Int) async throws -> [BaseItemDto]
    func fetchAudioMuseInfo() async throws -> AudioMusePluginInfo
    func checkAudioMuseHealth() async throws -> Bool
    func fetchActiveAudioMuseTask() async throws -> AudioMuseTaskStatus?
}

struct AudioMusePluginInfo: Decodable, Equatable {
    let version: String
    let availableEndpoints: [String]

    enum CodingKeys: String, CodingKey {
        case version = "Version"
        case availableEndpoints = "AvailableEndpoints"
    }
}

struct AudioMuseTaskStatus: Decodable, Equatable {
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
