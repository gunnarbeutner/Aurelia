//
//  AureliaScriptCommands.swift
//  Aurelia
//
//  AppleScript command handlers (Mac Catalyst only)
//

#if targetEnvironment(macCatalyst)
import Foundation

/// Bridges Apple events to app state.
///
/// Every command reports what actually happened rather than leaving the caller
/// to infer it from the view hierarchy, and anything that changes presentation
/// applies without animation so the result is settled by the time the command
/// returns. Commands that navigate suspend the Apple event until the push
/// lands, so a script never races the UI.
enum AureliaScripting {
    /// Player state as reported to scripts.
    enum PlayerState: String {
        case presented
        case hidden
        case noTrack = "no track"
    }

    static let tabNames = ["discover", "library", "search", "favorites", "settings"]

    /// How long a scripted navigation waits for the push to land. The view
    /// stages navigation through a short delay, so this only needs to outlast
    /// that plus a little slack.
    private static let navigationTimeout: TimeInterval = 3

    // MARK: - Player presentation

    @MainActor
    static func playerState() -> PlayerState {
        guard PlayerManager.shared.currentTrack != nil else { return .noTrack }
        return NavigationCoordinator.shared.isPlayerPresented ? .presented : .hidden
    }

    /// Presentation is impossible without a loaded track, and saying so beats a
    /// silent no-op.
    @MainActor
    static func setPlayerPresented(_ presented: Bool) -> PlayerState {
        guard PlayerManager.shared.currentTrack != nil else { return .noTrack }
        NavigationCoordinator.shared.pendingPlayerPresentation = presented
        return presented ? .presented : .hidden
    }

    // MARK: - Playback

    @MainActor
    static func play() -> String {
        let player = PlayerManager.shared
        guard player.currentTrack != nil else { return PlayerState.noTrack.rawValue }
        player.play()
        return "playing"
    }

    @MainActor
    static func pause() -> String {
        let player = PlayerManager.shared
        guard player.currentTrack != nil else { return PlayerState.noTrack.rawValue }
        player.pause()
        return "paused"
    }

    @MainActor
    static func skip(forward: Bool) -> String {
        let player = PlayerManager.shared
        guard player.currentTrack != nil else { return PlayerState.noTrack.rawValue }
        if forward {
            player.playNext()
        } else {
            player.playPrevious()
        }
        return nowPlaying()
    }

    @MainActor
    static func nowPlaying() -> String {
        guard let track = PlayerManager.shared.currentTrack else {
            return PlayerState.noTrack.rawValue
        }
        return [track.name, track.artistName, track.albumName]
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
    }

    // MARK: - Navigation

    @MainActor
    static func selectTab(named name: String) -> String {
        let wanted = normalize(name)
        guard let index = tabNames.firstIndex(where: { $0 == wanted }) else {
            return "unknown tab"
        }
        NavigationCoordinator.shared.pendingTabSelection = index
        return tabNames[index]
    }

    /// Resolves against the local catalog — the library is fully in SQLite, so
    /// this needs no network round trip — then waits for the push to land.
    @MainActor
    static func showArtist(named name: String) async -> String {
        guard let snapshot = await catalogSnapshot() else { return "not signed in" }
        guard let artist = match(name, in: snapshot.artists, name: \.name) else {
            return "no match"
        }
        NavigationCoordinator.shared.pendingArtistNavigation = artist
        return await waitForNavigation()
    }

    @MainActor
    static func showAlbum(named name: String) async -> String {
        guard let snapshot = await catalogSnapshot() else { return "not signed in" }
        guard let album = match(name, in: snapshot.albums, name: \.name) else {
            return "no match"
        }
        NavigationCoordinator.shared.pendingAlbumNavigation = album
        return await waitForNavigation()
    }

    // MARK: - Helpers

    @MainActor
    private static func catalogSnapshot() async -> LibrarySnapshot? {
        guard let scope = JellyfinService.shared.libraryScope else { return nil }
        return try? await LibraryRepository.shared.librarySnapshot(
            in: scope,
            includeTracks: false
        )
    }

    /// Exact match wins; otherwise fall back to a prefix so callers can pass a
    /// recognisable fragment rather than an exact title.
    private static func match<T>(
        _ query: String,
        in items: [T],
        name: KeyPath<T, String>
    ) -> T? {
        let wanted = normalize(query)
        return items.first { normalize($0[keyPath: name]) == wanted }
            ?? items.first { normalize($0[keyPath: name]).hasPrefix(wanted) }
    }

    @MainActor
    private static func waitForNavigation() async -> String {
        let coordinator = NavigationCoordinator.shared
        let deadline = Date().addingTimeInterval(navigationTimeout)
        while Date() < deadline {
            if coordinator.libraryNavigationDepth > 0 { return "navigated" }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return "timed out"
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

// MARK: - Commands

/// Runs `body` on the main actor and returns its result to the Apple event.
private func scriptResult(_ body: @MainActor () -> String) -> Any? {
    MainActor.assumeIsolated { body() }
}

/// Suspends the Apple event until `body` finishes, so scripted navigation
/// returns only once the UI has settled.
private func suspendingScriptResult(
    _ command: NSScriptCommand,
    _ body: @escaping @MainActor () async -> String
) -> Any? {
    command.suspendExecution()
    Task { @MainActor in
        command.resumeExecution(withResult: await body())
    }
    return nil
}

final class AureliaShowPlayerCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        scriptResult { AureliaScripting.setPlayerPresented(true).rawValue }
    }
}

final class AureliaHidePlayerCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        scriptResult { AureliaScripting.setPlayerPresented(false).rawValue }
    }
}

final class AureliaPlayerStateCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        scriptResult { AureliaScripting.playerState().rawValue }
    }
}

final class AureliaPlayCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        scriptResult { AureliaScripting.play() }
    }
}

final class AureliaPauseCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        scriptResult { AureliaScripting.pause() }
    }
}

final class AureliaNextTrackCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        scriptResult { AureliaScripting.skip(forward: true) }
    }
}

final class AureliaPreviousTrackCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        scriptResult { AureliaScripting.skip(forward: false) }
    }
}

final class AureliaNowPlayingCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        scriptResult { AureliaScripting.nowPlaying() }
    }
}

final class AureliaSelectTabCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let name = directParameter as? String else { return "missing tab name" }
        return scriptResult { AureliaScripting.selectTab(named: name) }
    }
}

final class AureliaShowArtistCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let name = directParameter as? String else { return "missing artist name" }
        return suspendingScriptResult(self) { await AureliaScripting.showArtist(named: name) }
    }
}

final class AureliaShowAlbumCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let name = directParameter as? String else { return "missing album name" }
        return suspendingScriptResult(self) { await AureliaScripting.showAlbum(named: name) }
    }
}
#endif
