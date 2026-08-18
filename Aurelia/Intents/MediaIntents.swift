//
//  MediaIntents.swift
//  Aurelia
//
//  App Intents for playback, exposed to Shortcuts, Siri and Spotlight
//

import AppIntents
import Foundation

// These intents live in the app target rather than an App Intents extension on
// purpose. `PlayerManager` owns the AVQueuePlayer singleton, so an extension
// process would mutate a different instance and silently play nothing. The
// transport intents the widget also names are in AureliaShared instead.

// MARK: - Start playback

struct PlayAlbumIntent: AppIntent {
    static var title: LocalizedStringResource { "Play Album" }
    static var description: IntentDescription {
        IntentDescription("Plays an album from your Jellyfin library.")
    }
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Album")
    var album: AlbumEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$album)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await AureliaActions.playAlbum(id: album.id, name: album.name)
        return .result(dialog: IntentDialog(stringLiteral: outcome.message))
    }
}

struct PlayArtistIntent: AppIntent {
    static var title: LocalizedStringResource { "Play Artist" }
    static var description: IntentDescription {
        IntentDescription("Plays everything by an artist in your Jellyfin library.")
    }
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Artist")
    var artist: ArtistEntity

    @Parameter(title: "Shuffle", default: false)
    var shuffle: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$artist)") {
            \.$shuffle
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await AureliaActions.playArtist(
            id: artist.id,
            name: artist.name,
            shuffled: shuffle
        )
        return .result(dialog: IntentDialog(stringLiteral: outcome.message))
    }
}

struct PlayPlaylistIntent: AppIntent {
    static var title: LocalizedStringResource { "Play Playlist" }
    static var description: IntentDescription {
        IntentDescription("Plays a playlist from your Jellyfin library.")
    }
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Playlist")
    var playlist: PlaylistEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$playlist)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await AureliaActions.playPlaylist(id: playlist.id, name: playlist.name)
        return .result(dialog: IntentDialog(stringLiteral: outcome.message))
    }
}

struct StartInstantMixIntent: AppIntent {
    static var title: LocalizedStringResource { "Start Instant Mix" }
    static var description: IntentDescription {
        IntentDescription("Builds a mix of similar music seeded by an artist.")
    }
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Artist")
    var artist: ArtistEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Start an Instant Mix from \(\.$artist)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = AureliaActions.startInstantMix(seedID: artist.id, name: artist.name)
        return .result(dialog: IntentDialog(stringLiteral: outcome.message))
    }
}

// MARK: - Query

struct NowPlayingIntent: AppIntent {
    static var title: LocalizedStringResource { "Get Current Track" }
    static var description: IntentDescription {
        IntentDescription("Reports the track Aurelia is playing.")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let description = AureliaActions.nowPlayingDescription()
        return .result(
            value: description,
            dialog: IntentDialog(stringLiteral: description)
        )
    }
}
