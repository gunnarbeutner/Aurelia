//
//  NowPlayingSnapshotTests.swift
//  AureliaTests
//
//  The snapshot the widget reads, and the clock it carries forward.
//
//  The widget is only reloaded when the track or the transport state changes,
//  so between reloads it has to project the position itself. These cover that
//  projection, because getting it wrong shows up as a progress bar that runs
//  while the music is paused — or one that never moves at all.
//

import Foundation
import Testing

@testable import Aurelia

private func snapshot(
    isPlaying: Bool,
    elapsed: TimeInterval,
    duration: TimeInterval,
    writtenAt: Date
) -> NowPlayingSnapshot {
    NowPlayingSnapshot(
        trackID: "track-1",
        title: "Sixteen Bars",
        artistName: "Test Artist",
        albumName: "Test Album",
        albumID: "album-1",
        isPlaying: isPlaying,
        duration: duration,
        elapsed: elapsed,
        writtenAt: writtenAt,
        artworkFileName: nil
    )
}

@Suite struct NowPlayingSnapshotTests {
    private let written = Date(timeIntervalSinceReferenceDate: 1_000_000)

    @Test func aPlayingSnapshotCarriesItsPositionForward() {
        let state = snapshot(isPlaying: true, elapsed: 30, duration: 200, writtenAt: written)
        #expect(state.elapsed(at: written.addingTimeInterval(15)) == 45)
    }

    @Test func aPausedSnapshotHoldsItsPosition() {
        let state = snapshot(isPlaying: false, elapsed: 30, duration: 200, writtenAt: written)
        #expect(state.elapsed(at: written.addingTimeInterval(600)) == 30)
    }

    @Test func projectionStopsAtTheEndOfTheTrack() {
        let state = snapshot(isPlaying: true, elapsed: 190, duration: 200, writtenAt: written)
        #expect(state.elapsed(at: written.addingTimeInterval(500)) == 200)
        #expect(state.progress(at: written.addingTimeInterval(500)) == 1)
    }

    /// A widget can be drawn from a snapshot written before the device slept.
    @Test func projectionNeverRunsBackwards() {
        let state = snapshot(isPlaying: true, elapsed: 30, duration: 200, writtenAt: written)
        #expect(state.elapsed(at: written.addingTimeInterval(-60)) == 0)
    }

    @Test func aTrackWithNoDurationHasNoProgress() {
        let state = snapshot(isPlaying: true, elapsed: 30, duration: 0, writtenAt: written)
        #expect(state.progress(at: written) == 0)
    }

    /// The progress views animate across this range on their own, so it has to
    /// start where the track did rather than where the snapshot was written.
    @Test func theTimelineIsAnchoredToTheStartOfTheTrack() {
        let state = snapshot(isPlaying: true, elapsed: 30, duration: 200, writtenAt: written)
        #expect(state.timelineRange.lowerBound == written.addingTimeInterval(-30))
        #expect(state.timelineRange.upperBound == written.addingTimeInterval(170))
    }

    @Test func aSnapshotSurvivesEncodingForTheSharedContainer() throws {
        let state = snapshot(isPlaying: true, elapsed: 30, duration: 200, writtenAt: written)
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(NowPlayingSnapshot.self, from: data) == state)
    }

    /// A pause that reached the widget as "still playing" was the bug behind
    /// this: the transport state has to count as a display difference.
    @Test func pausingCountsAsADisplayChange() {
        let playing = snapshot(isPlaying: true, elapsed: 30, duration: 200, writtenAt: written)
        let paused = snapshot(isPlaying: false, elapsed: 30, duration: 200, writtenAt: written)
        #expect(!playing.matchesDisplay(of: paused, tolerance: 1.5))
    }

    @Test func aRepublishOfTheSameStateIsNotADisplayChange() {
        let first = snapshot(isPlaying: true, elapsed: 30, duration: 200, writtenAt: written)
        let later = snapshot(
            isPlaying: true,
            elapsed: 40,
            duration: 200,
            writtenAt: written.addingTimeInterval(10)
        )
        #expect(first.matchesDisplay(of: later, tolerance: 1.5))
    }

    @Test func aSeekCountsAsADisplayChange() {
        let first = snapshot(isPlaying: true, elapsed: 30, duration: 200, writtenAt: written)
        let seeked = snapshot(
            isPlaying: true,
            elapsed: 120,
            duration: 200,
            writtenAt: written.addingTimeInterval(10)
        )
        #expect(!first.matchesDisplay(of: seeked, tolerance: 1.5))
    }

    @Test func aDifferentTrackCountsAsADisplayChange() {
        let first = snapshot(isPlaying: true, elapsed: 30, duration: 200, writtenAt: written)
        var second = first
        second.trackID = "track-2"
        #expect(!first.matchesDisplay(of: second, tolerance: 1.5))
    }

    @Test func theEmptySnapshotReadsAsAPlaceholder() {
        #expect(NowPlayingSnapshot.placeholder.isPlaceholder)
        #expect(!snapshot(isPlaying: false, elapsed: 0, duration: 1, writtenAt: written).isPlaceholder)
    }
}
