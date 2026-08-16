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

    @Test func theQualityChosenIsWhatTheServerIsAskedFor() throws {
        // The quality setting was decoration for a long time: the URL carried
        // static=true, which tells Jellyfin to send the original file and
        // override the bitrate, so Low and Original fetched the same bytes.
        func query(_ bitrate: Int, startingAt offset: TimeInterval = 0) throws -> [String: String] {
            let url = StreamURL.universal(
                baseURL: "https://music.example",
                itemID: "track-1",
                token: "secret",
                userID: "listener",
                deviceID: "device-1",
                bitrate: bitrate,
                startingAt: offset
            )
            let items = URLComponents(url: try #require(url), resolvingAgainstBaseURL: false)?.queryItems ?? []
            return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        }

        #expect(try query(128)["MaxStreamingBitrate"] == "128000")
        #expect(try query(320)["MaxStreamingBitrate"] == "320000")

        // Nothing may reinstate the override that made the setting inert.
        #expect(try query(128)["static"] == nil)
    }

    @Test func seekingATranscodeAsksItToBeginThere() throws {
        func url(startingAt offset: TimeInterval) throws -> URL {
            try #require(StreamURL.universal(
                baseURL: "https://music.example/",
                itemID: "track-1",
                token: "secret",
                userID: nil,
                deviceID: "device-1",
                bitrate: 192,
                startingAt: offset
            ))
        }

        // A transcode answers no byte ranges, so a position is reached by
        // asking the server to start there. Ticks are ten-millionths of a second.
        let seeked = URLComponents(url: try url(startingAt: 90), resolvingAgainstBaseURL: false)
        #expect(seeked?.queryItems?.first { $0.name == "StartTimeTicks" }?.value == "900000000")

        // From the beginning there is nothing to ask for.
        let fromStart = URLComponents(url: try url(startingAt: 0), resolvingAgainstBaseURL: false)
        #expect(fromStart?.queryItems?.contains { $0.name == "StartTimeTicks" } == false)

        // A trailing slash on the server address must not double up.
        #expect(try url(startingAt: 0).absoluteString.contains("//Audio") == false)
    }

    @Test func aSeekIsPlannedByWhatItIsAimedAt() {
        // Three cases that look alike from the outside. Confusing them is how a
        // seek came to move the clock without moving the audio: a transcode was
        // seeked as though it answered byte ranges, which it does not.
        #expect(SeekPlan.resolve(requested: 60, duration: 200, isLoaded: true, isSeekable: true)
                == .direct(60))
        #expect(SeekPlan.resolve(requested: 60, duration: 200, isLoaded: true, isSeekable: false)
                == .restartStream(60))
        #expect(SeekPlan.resolve(requested: 60, duration: 200, isLoaded: false, isSeekable: true)
                == .remember(60))

        // Nothing is known about a track with no length, so there is nowhere to aim.
        #expect(SeekPlan.resolve(requested: 60, duration: 0, isLoaded: true, isSeekable: true)
                == .unavailable)
    }

    @Test func aSeekStaysInsideTheTrack() {
        #expect(SeekPlan.resolve(requested: -5, duration: 200, isLoaded: true, isSeekable: true)
                == .direct(0))
        #expect(SeekPlan.resolve(requested: 5_000, duration: 200, isLoaded: true, isSeekable: true)
                == .direct(200))

        // Clamped before it is remembered, so a paused player cannot store a
        // position its track does not have.
        #expect(SeekPlan.resolve(requested: 5_000, duration: 200, isLoaded: false, isSeekable: true)
                == .remember(200))
    }

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
