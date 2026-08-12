//
//  AureliaScriptCommands.swift
//  Aurelia
//
//  AppleScript command handlers (Mac Catalyst only)
//

#if targetEnvironment(macCatalyst)
import Foundation

/// Adapts Apple events onto ``AureliaActions``.
///
/// Only presentation and navigation live here — everything else is shared with
/// the App Intents surface. Commands that change presentation apply without
/// animation, and commands that navigate suspend the Apple event until the push
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

    // MARK: - Navigation

    @MainActor
    static func selectTab(named name: String) -> String {
        let wanted = AureliaActions.normalize(name)
        guard let index = tabNames.firstIndex(where: { $0 == wanted }) else {
            return "unknown tab"
        }
        NavigationCoordinator.shared.pendingTabSelection = index
        return tabNames[index]
    }

    @MainActor
    static func showArtist(named name: String) async -> String {
        guard await AureliaActions.snapshot() != nil else { return "not signed in" }
        guard let artist = await AureliaActions.findArtist(named: name) else {
            return "no match"
        }
        NavigationCoordinator.shared.pendingArtistNavigation = artist
        return await waitForNavigation()
    }

    @MainActor
    static func showAlbum(named name: String) async -> String {
        guard await AureliaActions.snapshot() != nil else { return "not signed in" }
        guard let album = await AureliaActions.findAlbum(named: name) else {
            return "no match"
        }
        NavigationCoordinator.shared.pendingAlbumNavigation = album
        return await waitForNavigation()
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
        scriptResult { AureliaActions.resume().message }
    }
}

final class AureliaPauseCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        scriptResult { AureliaActions.pause().message }
    }
}

final class AureliaNextTrackCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        scriptResult { AureliaActions.skip(forward: true).message }
    }
}

final class AureliaPreviousTrackCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        scriptResult { AureliaActions.skip(forward: false).message }
    }
}

final class AureliaNowPlayingCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        scriptResult { AureliaActions.nowPlayingDescription() }
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
