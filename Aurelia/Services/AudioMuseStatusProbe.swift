//
//  AudioMuseStatusProbe.swift
//  Aurelia
//
//  One reading of what the server says about AudioMuse.
//

import Foundation

/// The answer to a single reading.
nonisolated struct AudioMuseReading: Sendable {
    /// Nil means the request was cancelled and the server said nothing. The
    /// caller keeps whatever it already had rather than inventing a status.
    var availability: AudioMuseAvailability?
    /// True once the plugin has answered for itself. Callers carry this
    /// forward, because it is what stops a single failed request from
    /// reporting a working installation as missing.
    var confirmedPresence: Bool
}

/// Both Discover and Settings need to know what AudioMuse is doing, and the
/// rules for reading it are subtler than they look: presence is sticky, the
/// task endpoint is allowed to fail on its own, and a cancelled request is not
/// an outage. Keeping one copy of those rules is the point of this type —
/// the second copy had all three wrong.
enum AudioMuseStatusProbe {
    static func read(
        from api: DiscoveryAPI,
        presenceAlreadyConfirmed: Bool
    ) async -> AudioMuseReading {
        let info: AudioMusePluginInfo
        do {
            info = try await api.fetchAudioMuseInfo()
        } catch is CancellationError {
            return AudioMuseReading(availability: nil, confirmedPresence: presenceAlreadyConfirmed)
        } catch let error as URLError where error.code == .cancelled {
            return AudioMuseReading(availability: nil, confirmedPresence: presenceAlreadyConfirmed)
        } catch let error as JellyfinError {
            guard case .notFound = error else {
                return AudioMuseReading(
                    availability: .unavailable,
                    confirmedPresence: presenceAlreadyConfirmed
                )
            }
            // A confirmed installation cannot become "not installed" because
            // one request failed. Anything else is a plugin that has never
            // answered, which is the only honest way to report it missing.
            return AudioMuseReading(
                availability: presenceAlreadyConfirmed ? nil : .notInstalled,
                confirmedPresence: presenceAlreadyConfirmed
            )
        } catch {
            return AudioMuseReading(
                availability: .unavailable,
                confirmedPresence: presenceAlreadyConfirmed
            )
        }

        // Presence is established from here on, whatever the rest reports.
        do {
            if let task = try await api.fetchActiveAudioMuseTask() {
                return AudioMuseReading(availability: .analyzing(task), confirmedPresence: true)
            }
        } catch is CancellationError {
            return AudioMuseReading(availability: nil, confirmedPresence: true)
        } catch let error as URLError where error.code == .cancelled {
            return AudioMuseReading(availability: nil, confirmedPresence: true)
        } catch {
            // Task status is informative only. Its failure says nothing about
            // whether AudioMuse can serve recommendations.
            return AudioMuseReading(availability: .ready(version: info.version), confirmedPresence: true)
        }

        return AudioMuseReading(
            availability: (try? await api.checkAudioMuseHealth()) == true
                ? .ready(version: info.version)
                : .unavailable,
            confirmedPresence: true
        )
    }
}
