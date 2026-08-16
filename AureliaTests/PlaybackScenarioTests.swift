//
//  PlaybackScenarioTests.swift
//  AureliaTests
//
//  Common things a listener does, played out against the rules the player
//  follows: pressing next at the end of a queue, pressing previous twice,
//  resuming where a song was left off, then moving on from it.
//
//  These exercise the decisions rather than AVFoundation. Every bug they
//  describe was found by hand first — a position that leaked into the next
//  song, a queue that walked itself, a track that never reached its own end —
//  and each was a decision made in the wrong place, not a failure to talk to
//  the player.
//

import Foundation
import Testing

@testable import Aurelia

/// The parts of the player these rules act on, so a sequence of actions can be
/// followed without an audio engine underneath.
private struct Transport {
    var trackIDs: [String]
    var currentIndex: Int = 0
    var currentTime: TimeInterval = 0
    var repeatMode: PlayerManager.RepeatMode = .off
    var pendingStart: PendingStart?
    var isPlaying: Bool = true

    var currentTrackID: String { trackIDs[currentIndex] }

    /// Where the current track opens, and what it opens as.
    mutating func startCurrent() {
        currentTime = PendingStart.startTime(pendingStart, playing: currentTrackID) ?? 0
        pendingStart = nil
    }

    mutating func pressNext() {
        guard let next = QueueAdvance.nextIndex(
            current: currentIndex, count: trackIDs.count, repeatMode: repeatMode
        ) else {
            isPlaying = false
            return
        }
        currentIndex = next
        startCurrent()
    }

    mutating func pressPrevious() {
        switch PreviousAction.resolve(currentTime: currentTime, currentIndex: currentIndex) {
        case .restart:
            currentTime = 0
        case .step(let index):
            currentIndex = index
            startCurrent()
        }
    }

    /// Scrubbing before anything is loaded: the position is remembered for the
    /// track it was set on.
    mutating func scrubWhilePaused(to time: TimeInterval) {
        pendingStart = PendingStart(trackID: currentTrackID, time: time)
        currentTime = time
    }
}

struct PlaybackScenarioTests {

    @Test func seekingWhilePausedThenSkippingOpensTheNextTrackAtItsStart() {
        // Reported after a restart: scrub the restored track, press next, and
        // the new song opened partway through, because the remembered position
        // was not tied to anything.
        var transport = Transport(trackIDs: ["a", "b", "c"])
        transport.scrubWhilePaused(to: 90)
        #expect(transport.currentTime == 90)

        transport.pressNext()

        #expect(transport.currentTrackID == "b")
        #expect(transport.currentTime == 0)
        #expect(transport.pendingStart == nil)
    }

    @Test func resumingAfterARestartOpensWhereItWasLeft() {
        var transport = Transport(trackIDs: ["a", "b"], currentIndex: 0)
        transport.pendingStart = PendingStart(trackID: "a", time: 120)

        transport.startCurrent()

        #expect(transport.currentTime == 120)
        // Spent, so pausing and resuming again does not jump back.
        #expect(transport.pendingStart == nil)
    }

    @Test func pressingPreviousTwiceReachesTheSongBefore() {
        // The first press restarts, because a listener well into a song means
        // "again"; the second, now at the beginning, steps back.
        var transport = Transport(trackIDs: ["a", "b", "c"], currentIndex: 1, currentTime: 42)

        transport.pressPrevious()
        #expect(transport.currentTrackID == "b")
        #expect(transport.currentTime == 0)

        transport.pressPrevious()
        #expect(transport.currentTrackID == "a")
    }

    @Test func previousAtTheStartOfTheFirstTrackStaysPut() {
        var transport = Transport(trackIDs: ["a", "b"], currentIndex: 0, currentTime: 1)

        transport.pressPrevious()

        #expect(transport.currentTrackID == "a")
        #expect(transport.currentTime == 0)
    }

    @Test func nextAtTheEndStopsOrWrapsByRepeatMode() {
        var stopping = Transport(trackIDs: ["a", "b"], currentIndex: 1, repeatMode: .off)
        stopping.pressNext()
        #expect(stopping.currentTrackID == "b")
        #expect(!stopping.isPlaying)

        var wrapping = Transport(trackIDs: ["a", "b"], currentIndex: 1, repeatMode: .all)
        wrapping.pressNext()
        #expect(wrapping.currentTrackID == "a")
        #expect(wrapping.isPlaying)

        // Repeat-one governs a track ending by itself; Next is still a request
        // to move on, so it wraps rather than replaying.
        var single = Transport(trackIDs: ["a", "b"], currentIndex: 1, repeatMode: .one)
        single.pressNext()
        #expect(single.currentTrackID == "a")
    }

    @Test func skippingThroughAQueueLeavesEveryTrackAtItsStart() {
        var transport = Transport(trackIDs: ["a", "b", "c"], repeatMode: .all)
        transport.scrubWhilePaused(to: 100)

        for _ in 0..<4 {
            transport.pressNext()
            #expect(transport.currentTime == 0)
        }

        #expect(transport.currentTrackID == "b")
    }
}
