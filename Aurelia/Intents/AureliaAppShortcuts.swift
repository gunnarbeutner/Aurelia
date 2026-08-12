//
//  AureliaAppShortcuts.swift
//  Aurelia
//
//  Siri phrases and Spotlight entries for Aurelia's intents
//

import AppIntents

/// Spoken phrases for the media intents.
///
/// Two rules govern this list, and breaking the second one produces an App
/// Shortcut that fails at run time rather than at build time:
///
/// 1. Every phrase must contain `\(.applicationName)`.
/// 2. A required parameter must be bound in the phrase. An App Shortcut cannot
///    prompt for a parameter it was never given, so an unbound one fails with
///    "Unable to run App Shortcut" before `perform()` is ever reached.
struct AureliaAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayArtistIntent(),
            phrases: [
                "Play \(\.$artist) in \(.applicationName)"
            ],
            shortTitle: "Play Artist",
            systemImageName: "music.mic"
        )

        AppShortcut(
            intent: PlayAlbumIntent(),
            phrases: [
                "Play \(\.$album) in \(.applicationName)"
            ],
            shortTitle: "Play Album",
            systemImageName: "square.stack"
        )

        AppShortcut(
            intent: PlayPlaylistIntent(),
            phrases: [
                "Play \(\.$playlist) in \(.applicationName)"
            ],
            shortTitle: "Play Playlist",
            systemImageName: "music.note.list"
        )

        AppShortcut(
            intent: StartInstantMixIntent(),
            phrases: [
                "Start an Instant Mix from \(\.$artist) in \(.applicationName)"
            ],
            shortTitle: "Instant Mix",
            systemImageName: "sparkles"
        )

        AppShortcut(
            intent: ResumePlaybackIntent(),
            phrases: [
                "Resume \(.applicationName)"
            ],
            shortTitle: "Resume",
            systemImageName: "play.fill"
        )

        AppShortcut(
            intent: PausePlaybackIntent(),
            phrases: [
                "Pause \(.applicationName)"
            ],
            shortTitle: "Pause",
            systemImageName: "pause.fill"
        )

        AppShortcut(
            intent: NowPlayingIntent(),
            phrases: [
                "What's playing in \(.applicationName)"
            ],
            shortTitle: "Current Track",
            systemImageName: "waveform"
        )
    }
}
