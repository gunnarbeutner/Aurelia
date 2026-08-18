//
//  NowPlayingSnapshot.swift
//  AureliaShared
//
//  Now-playing state shared between the app and its widget extension
//

import Foundation

/// What the app mirrors out of the player so the widget extension can draw the
/// current track. The extension cannot read the app's containers, so this is
/// the whole of what it knows.
nonisolated struct NowPlayingSnapshot: Codable, Equatable, Hashable, Sendable {
    var trackID: String
    var title: String
    var artistName: String
    var albumName: String
    var albumID: String?
    var isPlaying: Bool
    var duration: TimeInterval

    /// Playback position at the moment this snapshot was written.
    var elapsed: TimeInterval

    /// When the snapshot was written. A playing timeline is projected forward
    /// from here rather than republished every second.
    var writtenAt: Date

    /// File name inside the shared artwork directory, not a full path: the
    /// container URL differs between the two processes.
    var artworkFileName: String?

    /// The position now, carried forward from `elapsed` while playing.
    func elapsed(at date: Date) -> TimeInterval {
        guard isPlaying else { return elapsed }
        let projected = elapsed + date.timeIntervalSince(writtenAt)
        return min(max(projected, 0), duration)
    }

    func progress(at date: Date) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(elapsed(at: date) / duration, 0), 1)
    }

    /// The window a progress view can animate across on its own. Anchored so
    /// that `startDate` is where the track began, even when that is in the
    /// past.
    var timelineRange: ClosedRange<Date> {
        let start = writtenAt.addingTimeInterval(-elapsed)
        let end = start.addingTimeInterval(max(duration, 1))
        return start...end
    }

    static let placeholder = NowPlayingSnapshot(
        trackID: "",
        title: "Nothing Playing",
        artistName: "Aurelia",
        albumName: "",
        albumID: nil,
        isPlaying: false,
        duration: 0,
        elapsed: 0,
        writtenAt: .distantPast,
        artworkFileName: nil
    )

    var isPlaceholder: Bool { trackID.isEmpty }

    /// Whether a widget drawn from this snapshot would look like one drawn
    /// from `other`. Position only counts when it has moved further than
    /// carrying the clock forward would explain.
    func matchesDisplay(of other: NowPlayingSnapshot, tolerance: TimeInterval) -> Bool {
        trackID == other.trackID
            && isPlaying == other.isPlaying
            && duration == other.duration
            && artworkFileName == other.artworkFileName
            && abs(elapsed(at: other.writtenAt) - other.elapsed) <= tolerance
    }
}
