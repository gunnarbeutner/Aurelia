//
//  PlaybackWiringTests.swift
//  AureliaTests
//
//  The player driven against a fake engine, so what it does in response to the
//  engine can be watched without an audio device.
//
//  The rules the player follows are covered next door in PlaybackScenarioTests.
//  These cover the wiring instead: that a track ending really does move the
//  queue, that an engine running ahead is caught in one step rather than
//  chased, and that seeking a transcode really does fetch a new stream. Each of
//  those was a bug that the rules alone could not have caught, because each was
//  the player reacting wrongly to something the engine said.
//

import Foundation
import Testing

@testable import Aurelia

// MARK: - A player with no audio underneath it

/// One item, with no media behind it.
@MainActor
private final class FakeItem: PlaybackItemHandle {
    let url: URL?
    let bufferedForStreaming: Bool
    var isReadyToPlay = true
    var hasFailed = false
    var playedTime: TimeInterval = 0
    /// Not a number, like a transcode, unless a test says otherwise.
    var loadedDuration: TimeInterval = .nan
    /// Every position this item was moved to, in order.
    private(set) var seeks: [TimeInterval] = []

    init(url: URL?, bufferedForStreaming: Bool) {
        self.url = url
        self.bufferedForStreaming = bufferedForStreaming
    }

    func seek(to time: TimeInterval, tolerance: TimeInterval, completion: @escaping (Bool) -> Void) {
        seeks.append(time)
        playedTime = time
        completion(true)
    }
}

/// An engine that plays nothing and can be told to behave like one that does.
@MainActor
private final class FakeEngine: PlaybackEngine {
    var onEvent: ((PlaybackEngineEvent) -> Void)?
    var rate: Float = 0
    var activity: PlaybackActivity = .paused

    /// What is left to play, current first. An item that has been played is
    /// dropped, which is what AVQueuePlayer does with its own queue.
    private(set) var items: [FakeItem] = []
    private(set) var isShutDown = false

    var currentItem: (any PlaybackItemHandle)? { current }

    var current: FakeItem? { items.first }

    func makeItem(url: URL, bufferedForStreaming: Bool) -> any PlaybackItemHandle {
        FakeItem(url: url, bufferedForStreaming: bufferedForStreaming)
    }

    func load(_ items: [any PlaybackItemHandle]) {
        self.items = items.compactMap { $0 as? FakeItem }
    }

    func append(_ item: any PlaybackItemHandle) {
        guard let item = item as? FakeItem else { return }
        items.append(item)
    }

    func remove(_ item: any PlaybackItemHandle) {
        items.removeAll { $0 === (item as? FakeItem) }
    }

    func replaceCurrentItem(with item: any PlaybackItemHandle) {
        guard let item = item as? FakeItem else { return }
        if items.isEmpty {
            items = [item]
        } else {
            items[0] = item
        }
    }

    func advanceToNextItem() {
        if !items.isEmpty { items.removeFirst() }
    }

    func play() {
        rate = 1
        activity = .playing
        onEvent?(.activityChanged(.playing))
    }

    func pause() {
        rate = 0
        activity = .paused
        onEvent?(.activityChanged(.paused))
    }

    func shutDown() {
        isShutDown = true
        items.removeAll()
        onEvent = nil
    }

    // MARK: Things a real engine does

    /// Reaches the end of the playing item and starts the next, which is the
    /// order AVFoundation does it in: the queue has already moved on by the
    /// time the end of the last item is reported.
    func finishCurrentItem(after played: TimeInterval) {
        guard let finished = current else { return }
        finished.playedTime = played
        items.removeFirst()
        onEvent?(.itemEnded(finished))
    }

    /// Moves on without saying so, which is what happens when end-of-item
    /// events are missed or arrive late.
    func silentlyAdvance(by positions: Int) {
        items.removeFirst(min(positions, items.count))
    }

    /// Ends up playing something nobody handed it, which is the state the queue
    /// cannot reason about.
    func playSomethingUnknown() {
        items.insert(FakeItem(url: URL(string: "https://music.example/elsewhere"), bufferedForStreaming: true), at: 0)
    }

    /// A position sample, by the playing item's own clock.
    func reportTime(_ seconds: TimeInterval) {
        current?.playedTime = seconds
        onEvent?(.timeObserved(seconds))
    }
}

/// A player wired to a fake engine, with the library and the network taken out
/// of the picture: tracks play from wherever the test says they do.
@MainActor
private final class Harness {
    let player: PlayerManager
    /// Every engine built so far. The player builds a fresh one per track, as
    /// the real one does.
    private let built = Engines()

    final class Engines {
        var all: [FakeEngine] = []
    }

    var engine: FakeEngine { built.all.last! }
    /// How many engines the player has built. More than one means it tore the
    /// last one down and started again.
    var enginesBuilt: Int { built.all.count }

    /// The state keys the player persists to, saved so a test cannot leave the
    /// app on this simulator restoring a queue of mock tracks.
    private let savedState: [String: Any]

    init(streamsFrom source: @escaping (Track, TimeInterval) -> URL?) {
        let keys = [
            "playerState_queue", "playerState_currentIndex", "playerState_currentTime",
            "playerState_shuffleEnabled", "playerState_repeatMode", "playerState_autoplayStartIndex",
        ]
        savedState = keys.reduce(into: [:]) { saved, key in
            saved[key] = UserDefaults.standard.object(forKey: key)
        }

        let built = built
        player = PlayerManager(
            engine: {
                let engine = FakeEngine()
                built.all.append(engine)
                return engine
            },
            playbackURL: source
        )
    }

    deinit {
        let keys = [
            "playerState_queue", "playerState_currentIndex", "playerState_currentTime",
            "playerState_shuffleEnabled", "playerState_repeatMode", "playerState_autoplayStartIndex",
        ]
        for key in keys {
            if let value = savedState[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}

/// Streams everything as a transcode, which is what the quality setting asks
/// for and what cannot be seeked into.
private func transcode(_ track: Track, startingAt offset: TimeInterval) -> URL? {
    var url = "https://music.example/Audio/\(track.id)/universal?MaxStreamingBitrate=320000"
    if offset > 0 {
        url += "&StartTimeTicks=\(Int(offset * 10_000_000))"
    }
    return URL(string: url)
}

/// Plays everything from disk, as a downloaded favourite does.
private func downloaded(_ track: Track, startingAt offset: TimeInterval) -> URL? {
    URL(fileURLWithPath: "/tmp/aurelia-tests/\(track.id).flac")
}

private func songs(_ count: Int, seconds: TimeInterval = 240) -> [Track] {
    (1...count).map {
        Track(
            id: "track-\($0)",
            name: "Song \($0)",
            artistName: "An Artist",
            albumName: "An Album",
            duration: seconds,
            artworkURL: nil
        )
    }
}

// MARK: - Tests

@MainActor
struct PlaybackWiringTests {

    @Test func startingAQueueLoadsTheTrackAndTheTwoBehindIt() {
        let harness = Harness(streamsFrom: transcode)

        harness.player.play(tracks: songs(5))

        // Three at a time: enough for the next song to be ready when this one
        // ends, without fetching a queue's worth of transcodes up front.
        #expect(harness.engine.items.count == 3)
        #expect(harness.engine.current?.url?.path == "/Audio/track-1/universal")
        #expect(harness.player.isPlaying)
        #expect(harness.engine.rate == 1)
    }

    @Test func aTrackEndingMovesTheQueueOnAndLoadsAnother() {
        let harness = Harness(streamsFrom: transcode)
        harness.player.play(tracks: songs(5))

        harness.engine.finishCurrentItem(after: 240)

        #expect(harness.player.currentIndex == 1)
        #expect(harness.player.currentTrack?.id == "track-2")
        // The new song opens at its own beginning, not where the last one got to.
        #expect(harness.player.playbackProgress.currentTime == 0)
        // Still three loaded, so the one after next is ready in time.
        #expect(harness.engine.items.count == 3)
        #expect(harness.engine.items.last?.url?.path == "/Audio/track-4/universal")
    }

    @Test func skippingForwardUsesTheTrackAlreadyLoaded() {
        // Rebuilding the engine here discards the item being asked for: the next
        // track is loaded and buffering as part of the window, so a skip used to
        // wait several seconds for a stream the server had already begun sending.
        let harness = Harness(streamsFrom: transcode)
        harness.player.play(tracks: songs(5))
        let alreadyLoaded = harness.engine.items[1]

        harness.player.playNext()

        #expect(harness.engine.current === alreadyLoaded)
        #expect(harness.enginesBuilt == 1)
        #expect(harness.player.currentIndex == 1)
        #expect(harness.player.currentTrack?.id == "track-2")
        #expect(harness.player.isPlaying)
        // And the window is topped back up behind it.
        #expect(harness.engine.items.count == 3)
        #expect(harness.engine.items.last?.url?.path == "/Audio/track-4/universal")
    }

    @Test func skippingForwardOpensTheTrackAtItsStart() {
        let harness = Harness(streamsFrom: transcode)
        harness.player.play(tracks: songs(5))
        harness.engine.reportTime(64)

        harness.player.playNext()
        harness.engine.reportTime(3)

        #expect(harness.player.playbackProgress.currentTime == 3)
        #expect(harness.player.duration == 240)
    }

    @Test func skippingForwardWhilePausedStartsPlaying() {
        let harness = Harness(streamsFrom: transcode)
        harness.player.play(tracks: songs(5))
        harness.player.pause()

        harness.player.playNext()

        #expect(harness.player.isPlaying)
        #expect(harness.engine.rate == 1)
        #expect(harness.enginesBuilt == 1)
    }

    @Test func skippingOntoATrackThatFailedToLoadRebuilds() {
        // It would never start, and nothing more is said about it, so the step
        // would end in silence until the stall watch gave up.
        let harness = Harness(streamsFrom: transcode)
        harness.player.play(tracks: songs(5))
        harness.engine.items[1].hasFailed = true

        harness.player.playNext()

        #expect(harness.enginesBuilt == 2)
        #expect(harness.player.currentIndex == 1)
        #expect(harness.engine.current?.url?.path == "/Audio/track-2/universal")
        #expect(harness.engine.current?.hasFailed == false)
    }

    @Test func skippingBeyondTheLoadedWindowRebuilds() {
        // Nothing has been loaded for a track three places away.
        let harness = Harness(streamsFrom: transcode)
        harness.player.play(tracks: songs(6))

        harness.player.jumpToTrack(at: 3)

        #expect(harness.enginesBuilt == 2)
        #expect(harness.player.currentIndex == 3)
        #expect(harness.engine.current?.url?.path == "/Audio/track-4/universal")
        #expect(harness.player.isPlaying)
    }

    @Test func skippingBackwardsRebuilds() {
        // The track before this one is behind the engine, not in front of it.
        let harness = Harness(streamsFrom: transcode)
        harness.player.play(tracks: songs(5), startingAt: 2)

        harness.player.playPrevious()

        #expect(harness.enginesBuilt == 2)
        #expect(harness.player.currentIndex == 1)
        #expect(harness.engine.current?.url?.path == "/Audio/track-2/universal")
    }

    @Test func skippingWhileTheEngineHasRunAheadRebuilds() {
        // What it is playing and what we hold already disagree; stepping again
        // would compound that rather than settle it.
        let harness = Harness(streamsFrom: transcode)
        harness.player.play(tracks: songs(5))
        harness.engine.silentlyAdvance(by: 1)

        harness.player.playNext()

        #expect(harness.enginesBuilt == 2)
        #expect(harness.player.currentIndex == 1)
        #expect(harness.engine.current?.url?.path == "/Audio/track-2/universal")
    }

    @Test func skippingWithNothingLoadedBehindRebuilds() {
        let harness = Harness(streamsFrom: transcode)
        harness.player.play(tracks: songs(2), startingAt: 1)
        harness.player.repeatMode = .all

        // Wrapping to the top is not one place forward.
        harness.player.playNext()

        #expect(harness.enginesBuilt == 2)
        #expect(harness.player.currentIndex == 0)
        #expect(harness.engine.current?.url?.path == "/Audio/track-1/universal")
    }

    @Test func skippingRepeatedlyWalksTheQueueOneTrackAtATime() {
        let harness = Harness(streamsFrom: transcode)
        harness.player.play(tracks: songs(8))

        for expected in 1...4 {
            harness.player.playNext()
            #expect(harness.player.currentIndex == expected)
            #expect(harness.player.currentTrack?.id == "track-\(expected + 1)")
        }

        // Every one of those was a step, so the engine was never rebuilt.
        #expect(harness.enginesBuilt == 1)
        #expect(harness.engine.items.count == 3)
    }

    @Test func everyTrackThatPlaysReachesRecentlyPlayed() {
        // Only tracks that arrived by rebuilding the player were listed, so a
        // song that simply followed the one before it was never recorded.
        let harness = Harness(streamsFrom: transcode)
        harness.player.play(tracks: songs(4))
        #expect(harness.player.recentlyPlayedTracks.first?.id == "track-1")

        harness.engine.finishCurrentItem(after: 240)
        #expect(harness.player.recentlyPlayedTracks.first?.id == "track-2")

        harness.player.playNext()
        #expect(harness.player.recentlyPlayedTracks.first?.id == "track-3")

        // Listed once each, newest first.
        #expect(harness.player.recentlyPlayedTracks.prefix(3).map(\.id)
                == ["track-3", "track-2", "track-1"])
    }

    @Test func anEndOfItemEventPartwayThroughIsIgnored() {
        // AVFoundation reports this mid-song sometimes. Believing it skips a
        // track the listener is still in the middle of.
        let harness = Harness(streamsFrom: transcode)
        harness.player.play(tracks: songs(5))

        harness.engine.finishCurrentItem(after: 12)

        #expect(harness.player.currentIndex == 0)
        #expect(harness.player.currentTrack?.id == "track-1")
    }

    @Test func reachingTheEndOfTheQueueStopsRatherThanWraps() {
        let harness = Harness(streamsFrom: transcode)
        harness.player.play(tracks: songs(2), startingAt: 1)

        harness.engine.finishCurrentItem(after: 240)

        #expect(!harness.player.isPlaying)
        #expect(harness.player.currentTrack?.id == "track-2")
    }

    @Test func repeatOneStartsTheSameTrackAgain() {
        let harness = Harness(streamsFrom: transcode)
        harness.player.play(tracks: songs(3))
        harness.player.repeatMode = .one

        harness.engine.finishCurrentItem(after: 240)

        #expect(harness.player.currentIndex == 0)
        #expect(harness.player.currentTrack?.id == "track-1")
        // Rebuilt rather than resumed: the engine may already have dropped the
        // finished item, and repeat has to reach the real beginning.
        #expect(harness.engine.current?.url?.path == "/Audio/track-1/universal")
        #expect(harness.player.isPlaying)
    }

    @Test func anEngineRunningAheadIsCaughtUpInOneStep() {
        // The queue used to advance one position per sample while the engine
        // stayed further ahead, so it never caught up and walked through the
        // whole queue instead — several songs skipped in a few seconds.
        let harness = Harness(streamsFrom: transcode)
        harness.player.play(tracks: songs(6))

        harness.engine.silentlyAdvance(by: 2)
        for _ in 0..<StalledAdvanceRecovery.requiredMismatchedSamples {
            harness.engine.reportTime(4)
        }

        #expect(harness.player.currentIndex == 2)
        #expect(harness.player.currentTrack?.id == "track-3")

        // And it stays there: more samples of the same item do not keep moving.
        for _ in 0..<StalledAdvanceRecovery.requiredMismatchedSamples * 2 {
            harness.engine.reportTime(5)
        }
        #expect(harness.player.currentIndex == 2)
    }

    @Test func anEngineOnSomethingWeAreNotHoldingLeavesTheQueueAlone() {
        // Where it has got to is unknown, and advancing on a guess is what does
        // the damage.
        let harness = Harness(streamsFrom: transcode)
        harness.player.play(tracks: songs(6))

        harness.engine.playSomethingUnknown()
        for _ in 0..<(StalledAdvanceRecovery.requiredMismatchedSamples * 2) {
            harness.engine.reportTime(4)
        }

        #expect(harness.player.currentIndex == 0)
    }

    @Test func positionSamplesFollowThePlayingTrack() {
        let harness = Harness(streamsFrom: transcode)
        harness.player.play(tracks: songs(3))

        harness.engine.reportTime(37)

        #expect(harness.player.playbackProgress.currentTime == 37)
        #expect(harness.player.duration == 240)
    }

    @Test func seekingADownloadedTrackMovesWithinIt() {
        let harness = Harness(streamsFrom: downloaded)
        harness.player.play(tracks: songs(3))
        let item = harness.engine.current

        harness.player.seek(to: 90)

        #expect(item?.seeks.last == 90)
        // Nothing was exchanged: a file answers byte ranges.
        #expect(harness.engine.current === item)
        #expect(harness.player.playbackProgress.currentTime == 90)
    }

    @Test func seekingATranscodeFetchesAStreamThatBeginsThere() async throws {
        // A transcode is produced as it is sent — it answers no byte ranges, so
        // there is no position in it to move to. Seeking one used to move the
        // clock while the audio carried on from where it was.
        let harness = Harness(streamsFrom: transcode)
        harness.player.play(tracks: songs(3))
        let original = try #require(harness.engine.current)

        harness.player.seek(to: 90)

        let replacement = try #require(harness.engine.current as? FakeItem)
        #expect(replacement !== original)
        #expect(replacement.url?.query?.contains("StartTimeTicks=900000000") == true)
        #expect(harness.player.playbackProgress.currentTime == 90)

        // The tracks queued behind it are untouched.
        #expect(harness.engine.items.count == 3)
        #expect(harness.engine.items[1].url?.path == "/Audio/track-2/universal")

        // The new stream's own clock starts at nothing, so where it was cut is
        // added back — otherwise seeking to 1:30 would report 0:05 a moment later.
        try await Task.sleep(for: .milliseconds(900))
        harness.engine.reportTime(5)
        #expect(harness.player.playbackProgress.currentTime == 95)
    }

    @Test func aTrackEndingClearsTheOffsetTheLastSeekLeftBehind() async throws {
        // The offset belongs to one stream. Carrying it into the next song puts
        // that song's position 90 seconds ahead of where it is.
        let harness = Harness(streamsFrom: transcode)
        harness.player.play(tracks: songs(4))
        harness.player.seek(to: 90)
        try await Task.sleep(for: .milliseconds(900))

        harness.engine.finishCurrentItem(after: 240)
        harness.engine.reportTime(5)

        #expect(harness.player.currentTrack?.id == "track-2")
        #expect(harness.player.playbackProgress.currentTime == 5)
    }

    @Test func stoppingReleasesTheEngine() {
        let harness = Harness(streamsFrom: transcode)
        harness.player.play(tracks: songs(3))
        let engine = harness.engine

        harness.player.clearQueue()

        #expect(engine.isShutDown)
        #expect(!harness.player.isPlaying)
        #expect(harness.player.currentTrack == nil)
    }
}
