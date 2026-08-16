//
//  PlaybackReconciliationTests.swift
//  AureliaTests
//
//  `isPlaying` is what the listener asked for; the engine's activity is what is
//  actually happening. These cover the cases where the two disagree — the reason a
//  silent track could sit there showing a pause button.
//

import Testing
import AVFoundation
@testable import Aurelia

struct PlaybackReconciliationTests {

    private static let paused = PlaybackActivity.paused
    private static let waiting = PlaybackActivity.waitingToStart
    private static let playing = PlaybackActivity.playing

    @Test func aPlayerThatStoppedOnItsOwnClearsThePlayingState() {
        // The bug: player stopped, nothing asked it to, UI kept saying playing.
        #expect(
            PlaybackReconciliation.action(
                activity: Self.paused,
                intendsToPlay: true,
                isReconfiguring: false
            ) == .clearPlayingState
        )
    }

    @Test func aDeliberatePauseIsNotTreatedAsAFault() {
        // The listener pressed pause: intent and player already agree.
        #expect(
            PlaybackReconciliation.action(
                activity: Self.paused,
                intendsToPlay: false,
                isReconfiguring: false
            ) == .none
        )
    }

    @Test func rebuildingThePlayerNeverClearsThePlayingState() {
        // Track changes tear the player down and build a new one, passing
        // through every status on the way. None of it means playback stopped.
        for status in [Self.paused, Self.waiting, Self.playing] {
            #expect(
                PlaybackReconciliation.action(
                    activity: status,
                    intendsToPlay: true,
                    isReconfiguring: true
                ) == .none
            )
        }
    }

    @Test func waitingToStartIsAStallOnlyWhilePlaybackIsWanted() {
        #expect(
            PlaybackReconciliation.action(
                activity: Self.waiting,
                intendsToPlay: true,
                isReconfiguring: false
            ) == .markStalled
        )
        // Buffering ahead while paused is ordinary and worth no comment.
        #expect(
            PlaybackReconciliation.action(
                activity: Self.waiting,
                intendsToPlay: false,
                isReconfiguring: false
            ) == .none
        )
    }

    @Test func playbackStartingOnItsOwnRestoresTheIntent() {
        // A stall that resolves itself, or a resume from an interruption: the
        // player is playing, so the UI must stop claiming otherwise.
        #expect(
            PlaybackReconciliation.action(
                activity: Self.playing,
                intendsToPlay: false,
                isReconfiguring: false
            ) == .restorePlayingState
        )
    }

    @Test func healthyPlaybackAsksForNothing() {
        #expect(
            PlaybackReconciliation.action(
                activity: Self.playing,
                intendsToPlay: true,
                isReconfiguring: false
            ) == .none
        )
    }
}
