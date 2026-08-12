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
/// The player is an overlay gated on three separate conditions — a loaded
/// track, the owning tab being selected, and the presentation flag — and two of
/// them fail silently. Driving it from a script therefore reports what actually
/// happened rather than leaving the caller to infer it from the view hierarchy,
/// and applies the change without animation so the result is settled the moment
/// the command returns.
enum AureliaScripting {
    /// Player state as reported to scripts.
    enum PlayerState: String {
        case presented
        case hidden
        case noTrack = "no track"
    }

    @MainActor
    static func playerState() -> PlayerState {
        guard PlayerManager.shared.currentTrack != nil else { return .noTrack }
        return NavigationCoordinator.shared.isPlayerPresented ? .presented : .hidden
    }

    /// Requests presentation and reports the resulting state. Presentation is
    /// impossible without a loaded track, and saying so beats a silent no-op.
    @MainActor
    static func setPlayerPresented(_ presented: Bool) -> PlayerState {
        guard PlayerManager.shared.currentTrack != nil else { return .noTrack }
        NavigationCoordinator.shared.pendingPlayerPresentation = presented
        return presented ? .presented : .hidden
    }
}

final class AureliaShowPlayerCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            AureliaScripting.setPlayerPresented(true).rawValue
        }
    }
}

final class AureliaHidePlayerCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            AureliaScripting.setPlayerPresented(false).rawValue
        }
    }
}

final class AureliaPlayerStateCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            AureliaScripting.playerState().rawValue
        }
    }
}
#endif
