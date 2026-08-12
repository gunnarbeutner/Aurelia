//
//  AureliaActions.swift
//  Aurelia
//
//  Shared action layer behind AppleScript commands and App Intents
//

import Foundation

/// The app's scriptable actions in one place.
///
/// Both the Mac Catalyst AppleScript commands and the App Intents surface call
/// through here rather than reimplementing playback and lookup, so the two
/// cannot drift apart. Nothing in this file imports a UI framework.
@MainActor
enum AureliaActions {
    /// Outcome of an action, phrased for a caller that has no view hierarchy to
    /// inspect. Every failure is explicit — a silent no-op reads as a bug from
    /// the outside.
    enum Outcome: Equatable {
        case ok(String)
        case noTrack
        case notSignedIn
        case noMatch
        case empty

        var message: String {
            switch self {
            case .ok(let text): return text
            case .noTrack: return "no track"
            case .notSignedIn: return "not signed in"
            case .noMatch: return "no match"
            case .empty: return "nothing to play"
            }
        }
    }

    /// Matches the artist shuffle cap used by the artist screen so a scripted
    /// shuffle behaves like the button.
    nonisolated static let artistShuffleLimit = 200

    // MARK: - Playback

    static func resume() -> Outcome {
        let player = PlayerManager.shared
        guard player.currentTrack != nil else { return .noTrack }
        player.play()
        return .ok("playing")
    }

    static func pause() -> Outcome {
        let player = PlayerManager.shared
        guard player.currentTrack != nil else { return .noTrack }
        player.pause()
        return .ok("paused")
    }

    static func skip(forward: Bool) -> Outcome {
        let player = PlayerManager.shared
        guard player.currentTrack != nil else { return .noTrack }
        if forward {
            player.playNext()
        } else {
            player.playPrevious()
        }
        return .ok(nowPlayingDescription())
    }

    static func nowPlayingDescription() -> String {
        guard let track = PlayerManager.shared.currentTrack else {
            return Outcome.noTrack.message
        }
        return [track.name, track.artistName, track.albumName]
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
    }

    // MARK: - Start playback from the catalog

    static func playAlbum(id: String, name: String) async -> Outcome {
        await play(name: name) { scope, repository in
            try await repository.tracks(inAlbum: id, in: scope)
        }
    }

    static func playPlaylist(id: String, name: String) async -> Outcome {
        await play(name: name) { scope, repository in
            try await repository.tracks(inPlaylist: id, in: scope)
        }
    }

    static func playArtist(id: String, name: String, shuffled: Bool) async -> Outcome {
        await play(name: name, shuffled: shuffled) { scope, repository in
            let tracks = try await repository.tracks(forArtist: id, in: scope)
            return shuffled ? Array(tracks.shuffled().prefix(artistShuffleLimit)) : tracks
        }
    }

    static func startInstantMix(seedID: String, name: String) -> Outcome {
        InstantMixCoordinator.shared.play(itemId: seedID, itemName: name)
        return .ok("starting an Instant Mix from \(name)")
    }

    // MARK: - Catalog lookup

    /// Resolves a name against the local catalog. The library lives in SQLite,
    /// so this needs no network round trip and `no match` genuinely means the
    /// item is not in the user's library.
    static func findAlbum(named name: String) async -> Album? {
        guard let snapshot = await snapshot() else { return nil }
        return match(name, in: snapshot.albums, name: \.name)
    }

    static func findArtist(named name: String) async -> Artist? {
        guard let snapshot = await snapshot() else { return nil }
        return match(name, in: snapshot.artists, name: \.name)
    }

    static func findPlaylist(named name: String) async -> Playlist? {
        guard let snapshot = await snapshot() else { return nil }
        return match(name, in: snapshot.playlists, name: \.name)
    }

    static func snapshot() async -> LibrarySnapshot? {
        guard let scope = JellyfinService.shared.libraryScope else { return nil }
        return try? await LibraryRepository.shared.librarySnapshot(
            in: scope,
            includeTracks: false
        )
    }

    /// Full-text search over the local catalog, used to resolve spoken and
    /// typed names for App Intents parameters.
    static func searchCatalog(
        _ query: String,
        filter: LibrarySearchFilter,
        limit: Int = 25
    ) async -> [LibrarySearchResult] {
        guard let scope = JellyfinService.shared.libraryScope else { return [] }
        return (try? await LibraryRepository.shared.search(
            query,
            filter: filter,
            in: scope,
            limit: limit
        )) ?? []
    }

    /// Exact match wins; otherwise fall back to a prefix so callers can pass a
    /// recognisable fragment rather than an exact title.
    nonisolated static func match<T>(
        _ query: String,
        in items: [T],
        name: KeyPath<T, String>
    ) -> T? {
        let wanted = normalize(query)
        return items.first { normalize($0[keyPath: name]) == wanted }
            ?? items.first { normalize($0[keyPath: name]).hasPrefix(wanted) }
    }

    nonisolated static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    // MARK: - Private

    private static func play(
        name: String,
        shuffled: Bool = false,
        tracks: @Sendable (LibraryScope, LibraryRepository) async throws -> [Track]
    ) async -> Outcome {
        guard let scope = JellyfinService.shared.libraryScope else { return .notSignedIn }
        guard let resolved = try? await tracks(scope, LibraryRepository.shared),
              !resolved.isEmpty else {
            return .empty
        }
        let player = PlayerManager.shared
        player.shuffleEnabled = shuffled
        player.play(tracks: resolved, startingAt: 0)
        return .ok("playing \(name)")
    }
}
