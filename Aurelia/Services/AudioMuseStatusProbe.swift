//
//  AudioMuseStatusProbe.swift
//  Aurelia
//
//  A one-shot reading of what the server says about AudioMuse.
//

import Foundation

/// Settings reports whether AudioMuse is installed and reachable, which is a
/// standing fact about the server rather than about any one screen. Discover
/// tracks the same thing continuously for its own recommendations, so this is
/// deliberately a single question and answer: no observation, no retry, no
/// state to keep in step with the Discover view model.
enum AudioMuseStatusProbe {
    static func availability(from api: DiscoveryAPI) async -> AudioMuseAvailability {
        do {
            let info = try await api.fetchAudioMuseInfo()
            if let task = try await api.fetchActiveAudioMuseTask() {
                return .analyzing(task)
            }
            // Plugin present but refusing health checks is a different problem
            // from it not being there at all, and needs a different fix.
            return (try? await api.checkAudioMuseHealth()) == true
                ? .ready(version: info.version)
                : .unavailable
        } catch let error as JellyfinError {
            if case .notFound = error { return .notInstalled }
            return .unavailable
        } catch {
            return .unavailable
        }
    }
}
