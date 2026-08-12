//
//  AureliaAppShortcuts.swift
//  Aurelia
//
//  Siri phrases and Spotlight entries for Aurelia's intents
//

import AppIntents

/// Spoken phrases for the media intents.
///
/// Every phrase must contain `\(.applicationName)` — App Intents rejects any
/// that does not, at build time.
struct AureliaAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayArtistIntent(),
            phrases: [
                "Play an artist in \(.applicationName)",
                "Play music in \(.applicationName)"
            ],
            shortTitle: "Play Artist",
            systemImageName: "music.mic"
        )

        AppShortcut(
            intent: PlayAlbumIntent(),
            phrases: [
                "Play an album in \(.applicationName)"
            ],
            shortTitle: "Play Album",
            systemImageName: "square.stack"
        )

        AppShortcut(
            intent: PlayPlaylistIntent(),
            phrases: [
                "Play a playlist in \(.applicationName)"
            ],
            shortTitle: "Play Playlist",
            systemImageName: "music.note.list"
        )

        AppShortcut(
            intent: StartInstantMixIntent(),
            phrases: [
                "Start an Instant Mix in \(.applicationName)"
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
