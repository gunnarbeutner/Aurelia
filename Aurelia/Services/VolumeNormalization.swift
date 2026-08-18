//
//  VolumeNormalization.swift
//  Aurelia
//
//  Playing a shuffled library at one loudness, from the gain Jellyfin measured.
//
//  Jellyfin scans a track for loudness and reports how far it sits from a -18
//  LUFS reference — the same reference ReplayGain uses. All that is decided
//  here is what that number is worth as a volume, which is the part with a
//  right answer worth pinning down: the rest of the feature is fetching it and
//  handing it to the player.
//

import Foundation

/// Which measurement a track is played by, or none at all.
nonisolated enum NormalizationMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case off
    case track
    case album

    /// Off unless asked for: normalization is only as good as the scan behind
    /// it, and a library that has never been analysed would otherwise have its
    /// loudness quietly rearranged by whatever partial data exists.
    static let `default` = NormalizationMode.off
    static let defaultsKey = "volumeNormalization"

    /// What is stored, or the default when nothing is.
    static var current: NormalizationMode {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey) else { return `default` }
        return NormalizationMode(rawValue: raw) ?? `default`
    }

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .track: return "Track"
        case .album: return "Album"
        }
    }

    var description: String {
        switch self {
        case .off: return "Play everything as loud as it was mastered"
        case .track: return "Even out loudness song by song"
        case .album: return "Even out loudness album by album, keeping a quiet track quiet"
        }
    }
}

/// What a scan found for one track.
nonisolated struct NormalizationGain: Codable, Equatable, Sendable {
    /// Decibels this track is off the reference by.
    let track: Double?
    /// The same for the album it belongs to. Missing on servers older than the
    /// field, and on a track that belongs to no album.
    let album: Double?

    /// Nothing measured — an answer in its own right, and the reason a track is
    /// not asked about twice.
    static let unmeasured = NormalizationGain(track: nil, album: nil)

    func decibels(for mode: NormalizationMode) -> Double? {
        switch mode {
        case .off: return nil
        case .track: return track
        // The album's own figure is the whole point of the mode; without one,
        // the track's is nearer the mark than leaving it as mastered.
        case .album: return album ?? track
        }
    }
}

nonisolated enum VolumeNormalization {
    /// As far down as a track is ever taken. A master this loud does not exist,
    /// so a gain past it is a measurement gone wrong, and honouring it would
    /// leave a song all but silent.
    static let floorDecibels: Double = -24

    /// The volume a player should be given for a measured gain.
    ///
    /// Only ever quieter. The gain is positive for anything below the
    /// reference, and turning such a track up clips it whenever its peaks
    /// already sit near full scale — which nothing here knows, since the scan
    /// reports loudness and not peak. So a quiet track is left as it is and a
    /// loud one is brought down to meet it, which costs some headroom and
    /// cannot distort anything.
    static func volume(forDecibels decibels: Double?) -> Float {
        guard let decibels, decibels.isFinite, decibels < 0 else { return 1 }
        return Float(pow(10, max(decibels, floorDecibels) / 20))
    }

    static func volume(for gain: NormalizationGain?, mode: NormalizationMode) -> Float {
        volume(forDecibels: gain?.decibels(for: mode))
    }
}
