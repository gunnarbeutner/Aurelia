//
//  PlaybackTransportIntents.swift
//  AureliaShared
//
//  Transport intents shared by the app, Shortcuts and the widget extension
//

import AppIntents
import Foundation

nonisolated enum PlaybackCommand: String, Sendable {
    case resume
    case pause
    case next
    case previous
}

/// Runs a transport command against the player. The intents below are compiled
/// into the widget extension so its buttons can name them, but only the app
/// registers a handler — `AudioPlaybackIntent` is what gets them there.
enum PlaybackCommandBridge {
    static var handler: ((PlaybackCommand) -> String)?

    static func run(_ command: PlaybackCommand) -> String {
        guard let handler else { return "Aurelia is not running" }
        return handler(command)
    }
}

// MARK: - Transport

// These conform to `AudioPlaybackIntent` rather than plain `AppIntent` so a tap
// in a widget or Control Center runs them in the app, against the process that
// owns the AVQueuePlayer. A plain `AppIntent` would run inside the extension
// and mutate a `PlayerManager` nothing is listening to.

struct ResumePlaybackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource { "Resume Playback" }
    static var description: IntentDescription {
        IntentDescription("Resumes the current track.")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: PlaybackCommandBridge.run(.resume)))
    }
}

struct PausePlaybackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource { "Pause Playback" }
    static var description: IntentDescription {
        IntentDescription("Pauses the current track.")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: PlaybackCommandBridge.run(.pause)))
    }
}

struct NextTrackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource { "Next Track" }
    static var description: IntentDescription {
        IntentDescription("Skips to the next track in the queue.")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: PlaybackCommandBridge.run(.next)))
    }
}

struct PreviousTrackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource { "Previous Track" }
    static var description: IntentDescription {
        IntentDescription("Skips to the previous track in the queue.")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: PlaybackCommandBridge.run(.previous)))
    }
}

/// Play and pause behind one button, so a widget does not have to guess which
/// of the two the player will accept.
struct TogglePlaybackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource { "Play or Pause" }
    static var description: IntentDescription {
        IntentDescription("Plays the current track, or pauses it if it is already playing.")
    }

    @Parameter(title: "Playing")
    var isPlaying: Bool

    init() {}

    init(isPlaying: Bool) {
        self.isPlaying = isPlaying
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: PlaybackCommandBridge.run(isPlaying ? .pause : .resume)))
    }
}

/// The toggle form Control Center needs: it hands the intent the state it wants
/// rather than the state it saw.
struct SetPlaybackIntent: SetValueIntent, AudioPlaybackIntent {
    static var title: LocalizedStringResource { "Play or Pause" }
    static var description: IntentDescription {
        IntentDescription("Plays or pauses the current track.")
    }

    @Parameter(title: "Playing")
    var value: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: PlaybackCommandBridge.run(value ? .resume : .pause)))
    }
}
