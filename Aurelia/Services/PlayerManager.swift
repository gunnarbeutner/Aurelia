//
//  PlayerManager.swift
//  Aurelia
//
//  Audio player management for background playback and Now Playing integration
//  Rebuilt using proven JellyJam approach for reliable background audio
//

import Foundation
import AVFoundation
import MediaPlayer
import Combine
import UIKit
import os.log

/// High-frequency playback position updates are isolated from `PlayerManager` so
/// views interested only in stable playback state are not invalidated twice a second.
final class PlaybackProgress: ObservableObject {
    @Published private(set) var currentTime: Double = 0

    func update(to currentTime: Double) {
        self.currentTime = currentTime
    }
}

/// Where an explicit "next" lands in the queue.
///
/// Kept separate from the player so the wrap-versus-stop rule is testable, and
/// deliberately independent of repeat-one: that mode governs what happens when a
/// track ends by itself, not what the Next button does.
/// Resolves the AudioMuse continuation setting from what is on disk.
///
/// The distinction that matters is absent versus explicitly off, and
/// `UserDefaults.bool(forKey:)` reports both as false — so reading it that way
/// would silently pin every listener to the old default no matter what this
/// says. Hence the raw object.
enum AutoplayPreference {
    /// On unless the listener has turned it off: a queue that stops dead at the
    /// end is the surprising behaviour, not the continuation.
    static let `default` = true

    static func isEnabled(storedValue: Any?) -> Bool {
        storedValue as? Bool ?? `default`
    }
}

/// When the AudioMuse continuation is worth fetching.
///
/// Waiting for the final song meant Up Next was empty at exactly the moment it
/// was supposed to show what comes next, and left no time for AudioMuse to
/// answer before the queue ran dry. A few songs of lead time fixes both.
enum AutoplayPriming {
    /// Upcoming songs left before the continuation is fetched. Small enough
    /// that a long deliberate queue is not buried under suggestions early on.
    static let leadTime = 3

    /// Songs one continuation adds. The queue keeps extending in batches this
    /// size, so it only has to be enough to play on while the next one is
    /// fetched — a longer run of guesses just buries Up Next.
    static let batchSize = 20

    /// More than a batch needs, because the mix arrives with items that get
    /// dropped: songs already queued, and anything that is not audio.
    static let requestSize = 30

    /// Trims a mix down to one batch — deduplicated against what is queued,
    /// and capped. Non-audio entries are already gone by this point.
    static func batch(from suggestions: [Track], excluding excluded: Set<String>) -> [Track] {
        var seen = excluded
        var batch: [Track] = []
        for track in suggestions {
            guard batch.count < batchSize else { break }
            guard seen.insert(track.id).inserted else { continue }
            batch.append(track)
        }
        return batch
    }

    static func shouldPrime(currentIndex: Int, queueCount: Int) -> Bool {
        guard queueCount > 0, currentIndex >= 0, currentIndex < queueCount else { return false }
        return queueCount - 1 - currentIndex <= leadTime
    }

    /// Where the suggested run still begins, given where playback has got to.
    ///
    /// A suggestion stops being a suggestion the moment it plays: the listener
    /// is in it now, so the whole run reverts to being the queue rather than
    /// having the marker creep down the list one song at a time.
    static func startIndexStillAhead(currentIndex: Int, autoplayStartIndex: Int?) -> Int? {
        guard let autoplayStartIndex else { return nil }
        return currentIndex >= autoplayStartIndex ? nil : autoplayStartIndex
    }
}

enum QueueAdvance {
    static func nextIndex(
        current: Int,
        count: Int,
        repeatMode: PlayerManager.RepeatMode
    ) -> Int? {
        guard count > 0 else { return nil }
        if current < count - 1 { return current + 1 }
        // At the end: repeat wraps, off stops.
        return repeatMode == .off ? nil : 0
    }
}

/// What a seek should do about the medium it is aimed at.
///
/// Three cases that look alike from the outside and are not: nothing is loaded
/// yet, so the position is remembered for when it is; the medium answers byte
/// ranges, so the player can move within it; or it is a transcode produced as
/// it is sent, which has no position to move to and must be re-requested from
/// where playback should resume.
nonisolated enum SeekPlan: Equatable {
    /// No length is known, so there is nothing to seek within.
    case unavailable
    /// Nothing is loaded; begin here once something is.
    case remember(TimeInterval)
    case direct(TimeInterval)
    case restartStream(TimeInterval)

    static func resolve(
        requested: TimeInterval,
        duration: TimeInterval,
        isLoaded: Bool,
        isSeekable: Bool
    ) -> SeekPlan {
        guard duration > 0 else { return .unavailable }

        let target = max(0, min(requested, duration))
        guard isLoaded else { return .remember(target) }
        return isSeekable ? .direct(target) : .restartStream(target)
    }
}

/// What pressing Previous should do.
///
/// Well into a song it means "start this again"; at its beginning it means the
/// song before. The threshold is what makes a double press reach the previous
/// track rather than restarting twice.
nonisolated enum PreviousAction: Equatable {
    case restart
    case step(to: Int)

    static let restartThreshold: TimeInterval = 3

    static func resolve(currentTime: TimeInterval, currentIndex: Int) -> PreviousAction {
        if currentTime > restartThreshold { return .restart }
        return currentIndex > 0 ? .step(to: currentIndex - 1) : .restart
    }
}

enum PlaybackRestartRecovery {
    static func synchronizedPreviousTime(
        observerTime: Double,
        authoritativeTime: Double,
        threshold: Double = 5
    ) -> Double {
        abs(observerTime - authoritativeTime) > threshold
            ? authoritativeTime
            : observerTime
    }

    /// How many times a single track may be pulled back before it is left alone.
    static let maximumAttempts = 2

    /// Attempts older than this are forgotten, so a track that misbehaves once
    /// an hour is still recovered rather than written off for good.
    static let attemptWindow: TimeInterval = 30

    static func shouldRecover(
        newTime: Double,
        previousTime: Double,
        trackedTrackID: String?,
        currentTrackID: String?,
        isSeeking: Bool,
        recentAttempts: [Date] = [],
        now: Date = Date()
    ) -> Bool {
        guard !isSeeking,
              newTime < previousTime - 30,
              previousTime > 60,
              trackedTrackID == currentTrackID else {
            return false
        }

        // Seeking a transcoded stream is what restarts it: the server has no
        // position to resume from and begins again, which reads here as another
        // unexpected restart. Recovering from that restart seeks again, and the
        // song plays the same half second for as long as anyone listens. After
        // a couple of tries the position is a lost cause and the audio is not.
        return recentWithin(recentAttempts, window: attemptWindow, now: now) < maximumAttempts
    }

    /// How many of these happened recently enough to still count.
    static func recentWithin(_ attempts: [Date], window: TimeInterval, now: Date) -> Int {
        attempts.filter { now.timeIntervalSince($0) < window }.count
    }
}

/// Decides whether an end-of-item notification really means the song ended.
///
/// The engine starts the next item before it reports the end of the last, so by
/// then the observed playback position can already describe the *next* song.
/// Judging completion by that number reads a genuine advance as a false alarm
/// and strands the display on the finished track, so the item's own position is
/// the primary evidence; the observed time only decides when the item can no
/// longer report one.
enum TrackCompletion {
    /// Jellyfin's duration metadata routinely disagrees with the real stream
    /// length by a few seconds, so "the end" is a window rather than a point.
    static let tolerance: Double = 10

    static func isGenuine(
        itemPlayedTime: Double?,
        itemDuration: Double?,
        observedTime: Double,
        trackDuration: Double
    ) -> Bool {
        if let itemPlayedTime, itemPlayedTime.isFinite, itemPlayedTime > 0 {
            // Streams that transcode report an indefinite duration, in which
            // case the track's metadata length is the best yardstick we have.
            let reference = [itemDuration, trackDuration]
                .compactMap { $0 }
                .first { $0.isFinite && $0 > 0 }
            if let reference, reference - itemPlayedTime <= tolerance { return true }
        }
        return trackDuration - observedTime <= tolerance
    }
}

/// The queue player advancing on its own is normal for a beat; staying ahead of
/// the queue we track is not, and leaves the listener looking at the wrong song.
/// A position remembered for a track that is not playing yet.
///
/// Restoring state and scrubbing a paused player both want playback to begin
/// somewhere other than the start. Holding that as a bare number meant it
/// applied to whatever played next: seek, press next, and the new song opened
/// partway through.
nonisolated struct PendingStart: Equatable {
    let trackID: String
    let time: TimeInterval

    /// Only the beginning is worth nothing to remember, and a fresh tap should
    /// always open at 0:00.
    static let minimum: TimeInterval = 1.0

    /// Where this track should begin, if this is the track the position was for.
    static func startTime(_ pending: PendingStart?, playing trackID: String) -> TimeInterval? {
        guard let pending, pending.trackID == trackID, pending.time > minimum else { return nil }
        return pending.time
    }
}

enum StalledAdvanceRecovery {
    /// Time observer samples (half a second apart) to tolerate before forcing
    /// the queue back into step with what is actually playing.
    static let requiredMismatchedSamples = 3

    static func shouldForceAdvance(mismatchedSamples: Int) -> Bool {
        mismatchedSamples >= requiredMismatchedSamples
    }

    /// How many positions the queue must move to sit on what is playing.
    ///
    /// Nil when there is nothing to do, and nil when the playing item is not one
    /// we are holding: stepping the queue on a guess is what turns a lag of one
    /// track into a walk through the whole queue, a step every time the observer
    /// fires. Not knowing where we are is a reason to stop, not to keep moving.
    static func positionsToAdvance(playingIndex: Int?) -> Int? {
        guard let playingIndex, playingIndex > 0 else { return nil }
        return playingIndex
    }
}

/// `isPlaying` records what the listener asked for; the player's
/// `timeControlStatus` records what is actually happening. Deciding when the
/// two have come apart is kept here, away from the timers that act on it.
enum PlaybackReconciliation {
    enum Action: Equatable {
        case none
        /// The player stopped without being asked to, so the intent is stale.
        case clearPlayingState
        /// The player has been trying to start rather than playing.
        case markStalled
        /// The player is playing something the intent had given up on.
        case restorePlayingState
    }

    static func action(
        activity: PlaybackActivity,
        intendsToPlay: Bool,
        isReconfiguring: Bool
    ) -> Action {
        // A player being torn down and rebuilt passes through every state on
        // the way, and none of it describes what the listener wants.
        guard !isReconfiguring else { return .none }

        switch activity {
        case .playing:
            return intendsToPlay ? .none : .restorePlayingState
        case .waitingToStart:
            return intendsToPlay ? .markStalled : .none
        case .paused:
            return intendsToPlay ? .clearPlayingState : .none
        }
    }
}

/// Manages audio playback with AVPlayer and iOS Now Playing integration
/// Handles background audio, interruptions, and remote controls
class PlayerManager: NSObject, ObservableObject {
    static let shared = PlayerManager()

    private let logger = Logger(subsystem: "de.beutner.Aurelia", category: "PlayerManager")

    // MARK: - Published Properties
    @Published var currentTrack: Track?
    @Published var isPlaying = false {
        didSet {
            if isPlaying && playbackRate != 1.0 {
                engine?.rate = playbackRate
            }
        }
    }
    let playbackProgress = PlaybackProgress()
    private(set) var currentTime: Double {
        get { playbackProgress.currentTime }
        set { playbackProgress.update(to: newValue) }
    }
    @Published var duration: Double = 0
    @Published var isBuffering = false
    /// Playback the player is actually doing, as opposed to `isPlaying`, which
    /// only records what the user asked for. The two disagreeing is the whole
    /// reason this exists: a player that never starts, or that stops on its
    /// own, used to leave the UI insisting a silent track was playing.
    @Published private(set) var isStalled = false
    private var isSeeking = false
    @Published var errorMessage: String?

    // MARK: - Playback Queue
    @Published var queue: [Track] = []
    @Published var currentIndex: Int = 0
    @Published var shuffleEnabled = false
    @Published var repeatMode: RepeatMode = .off
    @Published var playbackRate: Float = 1.0
    @Published var continuePlayingSimilarMusic = AutoplayPreference.default {
        didSet {
            UserDefaults.standard.set(
                continuePlayingSimilarMusic,
                forKey: StateKey.continuePlayingSimilarMusic
            )
            if !continuePlayingSimilarMusic {
                cancelAutoplaySuggestions(removeUpcoming: true)
            } else {
                primeAutoplayIfNeeded()
            }
        }
    }
    /// The first queue index supplied by automatic AudioMuse continuation.
    /// Nil means every queued item was chosen explicitly by the listener.
    @Published private(set) var autoplayStartIndex: Int?

    enum RepeatMode: String {
        case off = "off"
        case all = "all"
        case one = "one"

        var systemImage: String {
            switch self {
            case .off:
                return "repeat"
            case .all:
                return "repeat"
            case .one:
                return "repeat.1"
            }
        }
    }

    // MARK: - Private Properties

    /// Built when a queue is loaded and released when it is torn down, so a nil
    /// engine means there is nothing to play — the state the app is in after a
    /// restart, with a restored queue but no audio yet.
    private var engine: (any PlaybackEngine)?
    /// How to build one. Injected so playback can be exercised without audio.
    private let makeEngine: () -> any PlaybackEngine
    /// The items we believe are queued, current first. The engine keeps its own
    /// copy of the same queue and can be ahead of this one.
    private var playerItems: [any PlaybackItemHandle] = []
    private var progressReportTimer: Timer?
    private var lastReportedItemId: String?
    private var cancellables = Set<AnyCancellable>()
    private let jellyfinService = JellyfinService.shared

    // MARK: - Playback reconciliation

    private var stallWorkItem: DispatchWorkItem?
    private var pausedReconcileWorkItem: DispatchWorkItem?
    /// Raised while the player is being torn down and rebuilt, when the
    /// `.paused` status it reports on the way through says nothing about what
    /// the user actually wants.
    private var isReconfiguringPlayer = false
    /// The current item should be taken back to 0:00 once it is ready to be
    /// seeked. Seeking an item that is not `readyToPlay` does nothing, and the
    /// item is routinely still `.unknown` a second after playback is asked for.
    private var pendingStartAtZero = false

    /// Waiting this long to start is worth showing to the user.
    private let stallNoticeDelay: TimeInterval = 8
    /// Waiting this long means it is not going to start on its own.
    private let stallFailureDelay: TimeInterval = 30
    /// An intentional pause during a track change resolves well inside this;
    /// anything still paused afterwards stopped without being asked to.
    private let pausedReconcileDelay: TimeInterval = 0.75

    /// Where a track is played from, when something other than the library and
    /// the user's quality setting decides it.
    private let resolvePlaybackURL: ((Track, TimeInterval) -> URL?)?

    /// Builds an item for a track, buffered for streaming unless it is held on
    /// disk. Nil when there is nowhere to play it from.
    private func makeItem(for track: Track, startingAt offset: TimeInterval = 0) -> (any PlaybackItemHandle)? {
        guard let engine, let url = playbackURL(for: track, startingAt: offset) else { return nil }
        return engine.makeItem(url: url, bufferedForStreaming: !url.isFileURL)
    }

    /// Get playback URL respecting user's streaming quality preference
    private func playbackURL(for track: Track, startingAt offset: TimeInterval = 0) -> URL? {
        if let resolvePlaybackURL {
            return resolvePlaybackURL(track, offset)
        }
        // Check offline first
        if let localURL = downloadManager.getLocalURL(for: track.id) {
            return localURL
        }
        let qualityRaw = UserDefaults.standard.string(forKey: "streamingQuality") ?? "medium"
        let quality = StreamingQuality(rawValue: qualityRaw) ?? .medium
        if quality == .original {
            return jellyfinService.getDownloadURL(for: track.id)
        } else {
            return jellyfinService.getStreamingURL(
                for: track.id, bitrate: quality.bitrate, startingAt: offset
            )
        }
    }

    /// Whether what is playing can be moved around in.
    ///
    /// A local file and the original-quality endpoint are ordinary media that
    /// answer byte ranges. A transcode is produced as it is sent: it carries no
    /// length and refuses ranges, so there is no position in it to move to.
    private var currentItemIsSeekable: Bool {
        guard let url = engine?.currentItem?.url else { return true }
        if url.isFileURL { return true }
        return !url.path.hasSuffix("/universal")
    }

    /// Where the current stream begins within the track.
    ///
    /// Zero for anything seekable. A transcode asked to start partway through is
    /// a stream of only the remainder and its clock starts at nothing, so the
    /// position it reports is read relative to where it was cut.
    private var streamStartOffset: TimeInterval = 0

    /// Moves within a transcode by fetching one that begins where we are going.
    ///
    /// Only the item being played is exchanged, so whatever was preloaded behind
    /// it still follows on.
    private func restartStream(at time: TimeInterval) {
        guard let engine, let track = currentTrack,
              let item = makeItem(for: track, startingAt: time) else {
            logger.error("❌ Cannot restart stream at \(time)s")
            return
        }

        logger.info("🔁 Restarting stream at \(time)s for '\(track.name)'")

        let wasPlaying = isPlaying
        isSeeking = true
        streamStartOffset = time
        currentTime = time
        lastValidPlaybackTime = time
        // The clock is about to jump legitimately; the detector would otherwise
        // read the new stream's fresh start as one that restarted by itself.
        restartRecoveryAttempts.removeAll()

        engine.replaceCurrentItem(with: item)
        if playerItems.isEmpty {
            playerItems = [item]
        } else {
            playerItems[0] = item
        }

        if wasPlaying { engine.play() }
        updateNowPlayingInfo()

        DispatchQueue.main.asyncAfter(deadline: .now() + pausedReconcileDelay) { [weak self] in
            self?.isSeeking = false
        }
    }
    private let downloadManager = DownloadManager.shared
    /// When this track was last pulled back to where it had got to.
    private var restartRecoveryAttempts: [Date] = []
    /// The lock screen's artwork, and the track it belongs to.
    private var nowPlayingArtwork: (trackID: String, artwork: MPMediaItemArtwork)?
    private var originalQueue: [Track] = []
    private var originalIndex: Int = 0
    private var lastValidPlaybackTime: Double = 0.0  // Track last known position to detect unexpected restarts
    private var mismatchedItemSamples = 0  // Consecutive samples where the player ran ahead of our queue
    private let statePersistenceQueue = DispatchQueue(
        label: "de.beutner.Aurelia.player-state-persistence",
        qos: .utility
    )
    private var autoplayRequestTask: Task<Void, Never>?
    private var autoplayRequestSeedID: String?
    /// A seed AudioMuse had nothing new to offer. Remembered because priming
    /// now runs several songs out, so without this the same dead end would be
    /// refetched at every one of those song changes.
    private var autoplayExhaustedSeedID: String?

    // MARK: - Playback State Persistence Keys
    private enum StateKey {
        static let queue = "playerState_queue"
        static let currentIndex = "playerState_currentIndex"
        static let currentTime = "playerState_currentTime"
        static let shuffleEnabled = "playerState_shuffleEnabled"
        static let repeatMode = "playerState_repeatMode"
        static let continuePlayingSimilarMusic = "continuePlayingSimilarMusic"
        static let autoplayStartIndex = "playerState_autoplayStartIndex"
    }

    /// Recently played tracks (track-level, not just album IDs)
    @Published var recentlyPlayedTracks: [Track] = []
    /// Tracks actually left during this app session, newest first.
    @Published private(set) var playbackHistory: [Track] = []
    private var recentPlayRevision: UInt64 = 0
    private var activePlaybackTrack: Track?

    // MARK: - Initialization

    override convenience init() {
        self.init(engine: { AVPlaybackEngine() })
    }

    init(
        engine makeEngine: @escaping () -> any PlaybackEngine,
        playbackURL: ((Track, TimeInterval) -> URL?)? = nil
    ) {
        self.makeEngine = makeEngine
        self.resolvePlaybackURL = playbackURL
        super.init()
        continuePlayingSimilarMusic = AutoplayPreference.isEnabled(
            storedValue: UserDefaults.standard.object(
                forKey: StateKey.continuePlayingSimilarMusic
            )
        )
        setupNotifications()
        // Configure audio session immediately when PlayerManager is created
        configureAudioSession()
        Task { [weak self] in
            await self?.loadRecentHistoryFromDatabase()
        }
    }

    // MARK: - State Persistence

    /// Save current playback state to UserDefaults.
    ///
    /// Encoding a large artist or playlist queue can be expensive. Normal
    /// playback saves run on a serial utility queue so tapping Play does not
    /// hold the main thread. Scene-background saves can request a synchronous
    /// flush so state is durable before the app is suspended.
    func savePlaybackState(synchronously: Bool = false) {
        guard !queue.isEmpty else { return }

        let queueSnapshot = queue
        let indexSnapshot = currentIndex
        let timeSnapshot = currentTime
        let shuffleSnapshot = shuffleEnabled
        let repeatSnapshot = repeatMode.rawValue
        let autoplayStartSnapshot = autoplayStartIndex
        let write = {
            if let data = try? JSONEncoder().encode(queueSnapshot) {
                UserDefaults.standard.set(data, forKey: StateKey.queue)
            }
            UserDefaults.standard.set(indexSnapshot, forKey: StateKey.currentIndex)
            UserDefaults.standard.set(timeSnapshot, forKey: StateKey.currentTime)
            UserDefaults.standard.set(shuffleSnapshot, forKey: StateKey.shuffleEnabled)
            UserDefaults.standard.set(repeatSnapshot, forKey: StateKey.repeatMode)
            if let autoplayStartSnapshot {
                UserDefaults.standard.set(autoplayStartSnapshot, forKey: StateKey.autoplayStartIndex)
            } else {
                UserDefaults.standard.removeObject(forKey: StateKey.autoplayStartIndex)
            }
        }

        if synchronously {
            statePersistenceQueue.sync(execute: write)
        } else {
            statePersistenceQueue.async(execute: write)
        }
        logger.info("💾 Saved playback state: \(self.currentTrack?.name ?? "none") @ \(self.currentTime)s")
    }

    /// Load saved playback state — returns true if state was restored
    @discardableResult
    func restorePlaybackState() -> Bool {
        guard let queueData = UserDefaults.standard.data(forKey: StateKey.queue),
              let savedQueue = try? JSONDecoder().decode([Track].self, from: queueData),
              !savedQueue.isEmpty else {
            return false
        }

        let savedIndex = UserDefaults.standard.integer(forKey: StateKey.currentIndex)
        let savedTime = UserDefaults.standard.double(forKey: StateKey.currentTime)
        let savedShuffle = UserDefaults.standard.bool(forKey: StateKey.shuffleEnabled)
        let savedRepeatRaw = UserDefaults.standard.string(forKey: StateKey.repeatMode) ?? ""
        let savedAutoplayStart = UserDefaults.standard.object(
            forKey: StateKey.autoplayStartIndex
        ) as? Int

        guard savedIndex < savedQueue.count else { return false }

        // Restore queue state (don't auto-play — just set up so user can resume)
        queue = savedQueue
        currentIndex = savedIndex
        currentTrack = savedQueue[savedIndex]
        shuffleEnabled = savedShuffle
        if let repeat_ = RepeatMode(rawValue: savedRepeatRaw) { repeatMode = repeat_ }
        if let savedAutoplayStart, savedQueue.indices.contains(savedAutoplayStart) {
            autoplayStartIndex = savedAutoplayStart
        }

        // Store the saved time so we can seek when user hits play
        pendingStart = PendingStart(trackID: savedQueue[savedIndex].id, time: savedTime)

        // The track is known, so its length and where it was left off are known
        // too. Without these the player shows 0:00 of 0:00 until playback
        // starts, which reads as an empty player rather than a paused one.
        duration = savedQueue[savedIndex].duration
        currentTime = min(savedTime, savedQueue[savedIndex].duration)
        lastValidPlaybackTime = currentTime

        logger.info("▶️ Restored state: \(self.currentTrack?.name ?? "none") @ \(savedTime)s (queue: \(savedQueue.count) tracks)")
        return true
    }

    /// Pending seek time — applied when playback starts after state restore
    private var pendingStart: PendingStart?

    private func addToRecentTracks(_ track: Track) {
        recentPlayRevision &+= 1
        recentlyPlayedTracks.removeAll { $0.id == track.id }
        recentlyPlayedTracks.insert(track, at: 0)
        if recentlyPlayedTracks.count > 100 {
            recentlyPlayedTracks = Array(recentlyPlayedTracks.prefix(100))
        }
        if let scope = jellyfinService.libraryScope {
            Task {
                await LibraryRepository.shared.recordLocalPlay(track, in: scope)
            }
        }
    }

    func recordPlaybackTransition(to track: Track) {
        if let outgoingTrack = activePlaybackTrack, outgoingTrack.id != track.id {
            playbackHistory.removeAll { $0.id == outgoingTrack.id }
            playbackHistory.insert(outgoingTrack, at: 0)
            if playbackHistory.count > 100 {
                playbackHistory = Array(playbackHistory.prefix(100))
            }
        }
        activePlaybackTrack = track
    }

    private func loadRecentHistoryFromDatabase() async {
        guard let scope = jellyfinService.libraryScope else { return }
        let startingRevision = recentPlayRevision
        await LibraryRepository.shared.importLegacyCacheIfNeeded(in: scope)
        let tracks = await LibraryRepository.shared.cachedRecentTracks(in: scope, limit: 100)
        guard recentPlayRevision == startingRevision else { return }
        recentlyPlayedTracks = tracks
    }

    // MARK: - Audio Session Configuration

    /// Configures audio session for background playback
    func configureAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()

            // Configure for playback with AirPlay support and background audio
            try audioSession.setCategory(.playback,
                                       mode: .default,
                                       options: [.allowAirPlay,
                                               .allowBluetoothA2DP])

            // Set audio session as active with options
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            // Configure for remote control
            UIApplication.shared.beginReceivingRemoteControlEvents()

            // Enable remote control events
            setupRemoteControls()

            logger.info("✅ Audio session configured successfully")

        } catch {
            errorMessage = "Audio setup failed: \(error.localizedDescription)"
            logger.error("❌ Failed to setup audio session: \(error.localizedDescription)")
        }
    }

    // MARK: - Playback Control

    /// Plays a single track
    func play(_ track: Track) {
        // Validate track before playing
        guard !track.id.isEmpty else {
            errorMessage = "Invalid track"
            logger.error("Cannot play track with empty ID")
            return
        }

        cancelAutoplaySuggestions(removeUpcoming: true)
        pendingStart = nil  // Fresh tap — always start from beginning
        queue = [track]
        currentIndex = 0
        playCurrentTrack()
    }

    /// Plays a list of tracks starting at index
    func play(tracks: [Track], startingAt index: Int = 0) {
        // Validate input
        guard !tracks.isEmpty else {
            errorMessage = "No tracks to play"
            logger.error("Empty tracks array provided")
            return
        }

        guard index >= 0 && index < tracks.count else {
            errorMessage = "Invalid track position"
            logger.error("Invalid starting index \(index) for \(tracks.count) tracks")
            return
        }

        // Filter out any invalid tracks
        let validTracks = tracks.filter { !$0.id.isEmpty }
        guard !validTracks.isEmpty else {
            errorMessage = "No valid audio tracks"
            logger.error("No valid audio tracks in the provided list")
            return
        }

        cancelAutoplaySuggestions(removeUpcoming: true)
        pendingStart = nil  // Fresh tap — always start from beginning
        originalQueue = validTracks
        originalIndex = min(index, validTracks.count - 1)

        if shuffleEnabled && validTracks.count > 1 {
            // Shuffle the queue but keep the starting track first
            var shuffled = validTracks
            let startingTrack = shuffled.remove(at: originalIndex)
            shuffled.shuffle()
            queue = [startingTrack] + shuffled
            currentIndex = 0
        } else {
            queue = validTracks
            currentIndex = originalIndex
        }

        playCurrentTrack()
    }

    /// Plays/pauses current track
    func togglePlayPause() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()

        // Restoring playback state recreates the queue and current-track metadata,
        // but AVPlayer itself cannot be persisted across launches. Lazily rebuild it
        // on the first play action so the saved position can be resumed.
        guard let engine else {
            if currentTrack != nil {
                playCurrentTrack()
            }
            return
        }

        if isPlaying {
            engine.pause()
            isPlaying = false
        } else {
            engine.play()
            isPlaying = true
        }

        updateNowPlayingInfo()
    }

    /// Resume playback
    func play() {
        guard let engine else {
            if currentTrack != nil {
                playCurrentTrack()
            }
            return
        }

        engine.play()
        isPlaying = true
        updateNowPlayingInfo()
        if let itemId = currentTrack?.id {
            let ticks = positionTicks()
            Task { await jellyfinService.reportPlaybackProgress(itemId: itemId, positionTicks: ticks, isPaused: false) }
        }
    }

    /// Pause playback
    func pause() {
        engine?.pause()
        isPlaying = false
        updateNowPlayingInfo()
        if let itemId = currentTrack?.id {
            let ticks = positionTicks()
            Task { await jellyfinService.reportPlaybackProgress(itemId: itemId, positionTicks: ticks, isPaused: true) }
        }
    }

    /// Skips to next track
    func playNext() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()

        // Repeat-one describes what happens when a track ends on its own, and
        // the end-of-item handler already owns that. Pressing Next is an
        // explicit request to move on, so it always advances.
        guard let nextIndex = QueueAdvance.nextIndex(
            current: currentIndex,
            count: queue.count,
            repeatMode: repeatMode
        ) else {
            // End of the queue with repeat off.
            isPlaying = false
            return
        }

        moveToTrack(at: nextIndex)
    }

    /// Moves to a track in the queue, stepping onto it when the engine has
    /// already loaded it and rebuilding around it when it has not.
    ///
    /// Rebuilding throws away the very item being asked for: the track after
    /// this one is loaded and buffering as part of the three-track window, so
    /// tearing the engine down means asking the server for a stream it had
    /// already started sending, and the listener waits for it with the new
    /// title and 0:00 already on screen.
    private func moveToTrack(at index: Int) {
        if stepOntoLoadedItem(at: index) { return }

        currentIndex = index
        engine?.pause()
        playCurrentTrack()
    }

    /// Steps onto the next track using the item already loaded behind this one.
    ///
    /// False when that cannot be done — anything other than one place forward,
    /// nothing loaded behind, or an engine that has moved on by itself — in
    /// which case the caller rebuilds instead. Nothing is left half-done: the
    /// engine having let go of the item is checked after advancing, and a
    /// rebuild starts from wherever it is.
    private func stepOntoLoadedItem(at index: Int) -> Bool {
        guard let engine,
              index == currentIndex + 1,
              queue.indices.contains(index),
              playerItems.count >= 2,
              !playerHasOutrunQueue() else { return false }

        let intended = playerItems[1]
        // One that has already failed will not start when it becomes current,
        // and nothing further is reported about it, so it would simply sit
        // there until the stall watch gave up on it.
        guard !intended.hasFailed else {
            logger.warning("⏭️ The loaded item for the next track has failed; rebuilding")
            return false
        }

        engine.advanceToNextItem()
        guard engine.currentItem === intended else {
            logger.warning("⏭️ Stepping forward did not land on the loaded item; rebuilding")
            return false
        }

        // Report stopped for the track being left, as a track ending does.
        stopProgressReporting(reportStopped: true)
        // A position remembered for the track being left has no bearing on this one.
        pendingStart = nil
        adoptNextItem(at: index)
        // Skipping is also a request to play, whatever the player was doing.
        addToRecentTracks(queue[index])
        engine.play()
        isPlaying = true
        logger.info("⏭️ Stepped onto the loaded item for '\(self.queue[index].name)'")
        return true
    }

    /// Skips to previous track
    func playPrevious() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()

        switch PreviousAction.resolve(currentTime: currentTime, currentIndex: currentIndex) {
        case .restart:
            seek(to: 0)
        case .step(let index):
            moveToTrack(at: index)
        }
    }

    /// Adds a track to the end of the queue
    func addToQueue(track: Track) {
        if currentTrack == nil {
            play(track)
            return
        }

        discardUpcomingAutoplay()
        queue.append(track)
    }

    /// Adds multiple tracks to the end of the queue, preserving their order.
    func addToQueue(tracks: [Track]) {
        guard !tracks.isEmpty else { return }

        if currentTrack == nil {
            play(tracks: tracks)
        } else {
            discardUpcomingAutoplay()
            queue.append(contentsOf: tracks)
        }
    }

    /// Insert track to play after current track
    func playNext(track: Track) {
        if currentTrack == nil {
            play(track)
            return
        }

        discardUpcomingAutoplay()
        let insertIndex = min(currentIndex + 1, queue.count)
        queue.insert(track, at: insertIndex)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
    }

    /// Inserts multiple tracks after the current track, preserving their order.
    func playNext(tracks: [Track]) {
        guard !tracks.isEmpty else { return }

        if currentTrack == nil {
            play(tracks: tracks)
            return
        }

        discardUpcomingAutoplay()
        let insertIndex = min(currentIndex + 1, queue.count)
        queue.insert(contentsOf: tracks, at: insertIndex)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
    }

    /// Add track to end of queue
    func playLast(track: Track) {
        if currentTrack == nil {
            play(track)
            return
        }

        discardUpcomingAutoplay()
        queue.append(track)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
    }

    /// Seeks to specific time
    func seek(to time: Double) {
        // Log seeks to beginning to help debug restarts
        if time == 0 {
            logger.info("🔄 Seeking to beginning of track: \(self.currentTrack?.name ?? "unknown")")
        }

        let plan = SeekPlan.resolve(
            requested: time,
            duration: duration,
            isLoaded: engine?.currentItem?.isReadyToPlay == true,
            isSeekable: currentItemIsSeekable
        )

        let clampedTime: TimeInterval
        switch plan {
        case .unavailable:
            logger.error("❌ Cannot seek - duration is 0 (track metadata issue)")
            return

        case .remember(let target):
            // After a restart the queue is restored but no player exists until
            // playback starts, so the request is kept rather than dropped and
            // the scrubber works on a paused player.
            logger.info("⏳ Nothing loaded yet; starting at \(target)s when play begins")
            if let trackID = currentTrack?.id {
                pendingStart = PendingStart(trackID: trackID, time: target)
            }
            currentTime = target
            lastValidPlaybackTime = target
            return

        case .restartStream(let target):
            restartStream(at: target)
            return

        case .direct(let target):
            clampedTime = target
        }

        guard engine?.currentItem != nil else { return }

        logger.info("🔍 Seeking to \(clampedTime)s (duration: \(self.duration)s)")

        // Mark seeking so the time observer/restart detector don't fight us
        isSeeking = true
        // Update currentTime immediately to prevent UI snapping back
        self.currentTime = clampedTime

        // Seeking the item itself is more reliable than seeking the queue.
        let targetItem = engine?.currentItem ?? playerItems.first
        targetItem?.seek(to: clampedTime, tolerance: 0.3) { [weak self] completed in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if completed {
                    self.logger.info("✅ Seek completed to \(clampedTime)s")

                    self.currentTime = clampedTime
                    // Update lastValidPlaybackTime so the restart detector doesn't
                    // misread the backward jump as a stream restart
                    self.lastValidPlaybackTime = clampedTime
                    self.updateNowPlayingInfo()
                } else {
                    self.logger.error("❌ Seek failed to \(clampedTime)s")
                }
                // Keep isSeeking true briefly so time observer doesn't fight the new position
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.isSeeking = false
                }
            }
        }
    }

    /// Toggles shuffle mode
    func toggleShuffle() {
        shuffleEnabled.toggle()

        if shuffleEnabled {
            // Enable shuffle - save original order and shuffle
            if originalQueue.isEmpty {
                originalQueue = queue
                originalIndex = currentIndex
            }

            // Shuffle queue keeping current track first
            guard let currentTrack = currentTrack,
                  let currentTrackIndex = queue.firstIndex(where: { $0.id == currentTrack.id }) else { return }

            var newQueue = queue
            newQueue.remove(at: currentTrackIndex)
            newQueue.shuffle()
            queue = [currentTrack] + newQueue
            currentIndex = 0
        } else {
            // Disable shuffle - restore original order
            if !originalQueue.isEmpty {
                queue = originalQueue
                // Find current track in original queue
                if let currentTrack = currentTrack,
                   let index = originalQueue.firstIndex(where: { $0.id == currentTrack.id }) {
                    currentIndex = index
                }
                originalQueue = []
            }
        }
    }

    /// Cycles through repeat modes
    func toggleRepeatMode() {
        switch repeatMode {
        case .off:
            repeatMode = .all
        case .all:
            repeatMode = .one
        case .one:
            repeatMode = .off
        }
        if repeatMode == .off {
            primeAutoplayIfNeeded()
        } else {
            cancelAutoplaySuggestions(removeUpcoming: true)
        }
    }

    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        engine?.rate = isPlaying ? rate : 0
    }

    func cyclePlaybackRate() {
        let rates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
        let currentIdx = rates.firstIndex(of: playbackRate) ?? 2
        let nextIdx = (currentIdx + 1) % rates.count
        setPlaybackRate(rates[nextIdx])
    }

    // MARK: - Queue Management

    /// Removes a track from the queue at the specified index
    func removeFromQueue(at index: Int) {
        guard index >= 0 && index < queue.count else { return }

        if let start = autoplayStartIndex, index < start {
            autoplayStartIndex = start - 1
        }

        // If removing current track, skip to next
        if index == currentIndex {
            if currentIndex < queue.count - 1 {
                // Skip to next without playing current again
                queue.remove(at: index)
                playCurrentTrack()
            } else if currentIndex > 0 {
                // Last track - go to previous
                queue.remove(at: index)
                currentIndex -= 1
                playCurrentTrack()
            } else {
                // Only track in queue
                queue.remove(at: index)
                currentTrack = nil
                engine?.pause()
                isPlaying = false
                cleanupPlayer()
            }
        } else if index < currentIndex {
            // Removing track before current - adjust index
            queue.remove(at: index)
            currentIndex -= 1
            // Rebuild gapless queue to reflect changes
            if isPlaying {
                setupGaplessQueue(startingAt: currentIndex)
                engine?.play()
            }
        } else {
            // Removing track after current - just remove
            queue.remove(at: index)
            // If it's in the preloaded buffer, rebuild gapless queue
            let bufferEnd = currentIndex + playerItems.count
            if index < bufferEnd && isPlaying {
                setupGaplessQueue(startingAt: currentIndex)
                engine?.play()
            }
            // Shortening the tail can be what brings the queue within reach of
            // the continuation, and no song change will follow to notice it.
            primeAutoplayIfNeeded()
        }
    }

    /// Moves a track in the queue from one index to another
    func moveInQueue(from source: Int, to destination: Int) {
        guard source >= 0 && source < queue.count,
              destination >= 0 && destination <= queue.count else { return }

        // Don't move to the same position
        guard source != destination else { return }

        let track = queue[source]
        queue.remove(at: source)

        // Adjust for removal
        let insertIndex = source < destination ? destination - 1 : destination
        queue.insert(track, at: insertIndex)

        // Update current index if needed
        if source == currentIndex {
            // Moving current track
            currentIndex = insertIndex
        } else if source < currentIndex && insertIndex >= currentIndex {
            // Moved a track from before to after current
            currentIndex -= 1
        } else if source > currentIndex && insertIndex <= currentIndex {
            // Moved a track from after to before current
            currentIndex += 1
        }

        // The engine is holding the tracks that used to come next. Drop those
        // and preload again from the new order, without disturbing what is
        // playing.
        if isPlaying, let engine {
            for item in playerItems.dropFirst() {
                engine.remove(item)
            }
            playerItems = Array(playerItems.prefix(1))

            for offset in 1...2 {
                let nextIndex = currentIndex + offset
                guard nextIndex < queue.count else { break }

                let nextTrack = queue[nextIndex]
                guard let item = makeItem(for: nextTrack) else {
                    logger.error("❌ Failed to preload track at index \(nextIndex): \(nextTrack.name)")
                    continue
                }

                engine.append(item)
                playerItems.append(item)
                logger.info("✅ Reloaded track \(offset) after reorder: \(nextTrack.name)")
            }
        }

        updateNowPlayingInfo()
    }

    /// Clears the entire queue
    func clearQueue() {
        cancelAutoplaySuggestions(removeUpcoming: false)
        queue.removeAll()
        currentIndex = 0
        currentTrack = nil
        activePlaybackTrack = nil
        playbackHistory.removeAll()
        engine?.pause()
        isPlaying = false
        cleanupPlayer()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// Removes every queued track after the current one without interrupting playback.
    func clearUpcomingQueue() {
        guard queue.indices.contains(currentIndex) else { return }
        let firstUpcomingIndex = currentIndex + 1
        guard firstUpcomingIndex < queue.count else { return }

        queue.removeSubrange(firstUpcomingIndex..<queue.endIndex)
        autoplayStartIndex = nil
        autoplayRequestTask?.cancel()
        autoplayRequestTask = nil
        autoplayRequestSeedID = nil

        // Do not let disabling shuffle resurrect tracks the user explicitly cleared.
        if shuffleEnabled {
            originalQueue = queue
            originalIndex = currentIndex
        }

        // Keep what is playing and remove only its preloaded successors.
        if let engine, let currentItem = engine.currentItem {
            for item in playerItems where item !== currentItem {
                engine.remove(item)
            }
            playerItems = [currentItem]
        } else {
            playerItems.removeAll()
        }

        savePlaybackState()
        updateNowPlayingInfo()
    }

    /// Jump to track at index in queue
    func jumpToTrack(at index: Int) {
        guard index >= 0 && index < queue.count else { return }
        moveToTrack(at: index)
    }

    /// Replays a session-history item without discarding the existing queue.
    func playFromHistory(_ track: Track) {
        let earlierMatch = currentIndex > 0
            ? (0..<min(currentIndex, queue.count)).last { queue[$0].id == track.id }
            : nil
        if let index = earlierMatch ?? queue.firstIndex(where: { $0.id == track.id }) {
            jumpToTrack(at: index)
        } else {
            play(track)
        }
    }

    // MARK: - Private Playback Methods

    private func playCurrentTrack() {
        guard currentIndex >= 0 && currentIndex < queue.count else {
            logger.error("Invalid queue index: \(self.currentIndex) (queue size: \(self.queue.count))")
            errorMessage = "Invalid track position"
            return
        }

        let track = queue[currentIndex]

        // Validate track data
        guard !track.id.isEmpty else {
            logger.error("Track has empty ID")
            errorMessage = "Invalid track data"
            playNext()
            return
        }

        currentTrack = track
        addToRecentTracks(track)

        // Reset time BEFORE saving state — so we don't persist the previous track's
        // position against this new track (which would cause mid-song starts on next restore)
        currentTime = 0
        lastValidPlaybackTime = 0

        // Set duration from track metadata (Jellyfin API provides this)
        // Don't rely on stream duration as HTTP transcoded streams report isIndefinite
        duration = track.duration
        savePlaybackState()
        logger.info("📏 Set duration from track metadata: \(track.duration)s for '\(track.name)'")

        // Clear any previous error
        errorMessage = nil
        isStalled = false

        // Tearing the player down and building a new one runs it through
        // `.paused` on the way. That is expected here and must not be mistaken
        // for the player stopping on its own.
        isReconfiguringPlayer = true
        defer { isReconfiguringPlayer = false }

        // Clean up previous player
        cleanupPlayer()

        // Streaming items can start mid-buffer if previously buffered, so a
        // fresh track is taken back to the beginning once its item is ready to
        // be seeked. Set before the observers attach: a local file can be ready
        // the moment it is observed, and would otherwise miss this entirely.
        pendingStartAtZero = true

        // Load the current track and the next two, for gapless playback.
        setupGaplessQueue(startingAt: currentIndex)

        // Ensure audio session is properly configured and active before playing
        do {
            let audioSession = AVAudioSession.sharedInstance()

            // Check if we need to reconfigure the audio session
            if audioSession.category != .playback {
                try audioSession.setCategory(.playback,
                                           mode: .default,
                                           options: [.allowAirPlay,
                                                   .allowBluetoothA2DP])
            }

            // Activate audio session
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            logger.info("✅ Audio session activated for playback")
        } catch {
            errorMessage = "Failed to configure audio: \(error.localizedDescription)"
            logger.error("Failed to activate audio session: \(error)")

            // Clean up on failure
            cleanupPlayer()
            return
        }

        // Ensure remote controls are set up
        setupRemoteControls()

        // Only transitions that actually reach playback belong in session history.
        recordPlaybackTransition(to: track)

        // Start playback
        engine?.play()
        isPlaying = true

        // Report playback start to Jellyfin
        startProgressReporting(for: track)


        // A position is only honoured for the track it was remembered for, so
        // advancing to the next song opens it at its own beginning.
        if let seekTo = PendingStart.startTime(pendingStart, playing: track.id) {
            pendingStart = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.seek(to: seekTo)
            }
        } else {
            pendingStart = nil
        }

        // Update Now Playing
        updateNowPlayingInfo()

        logger.info("▶️ Started playing: \(track.name)")
        autoplayStartIndex = AutoplayPriming.startIndexStillAhead(
            currentIndex: currentIndex,
            autoplayStartIndex: autoplayStartIndex
        )
        primeAutoplayIfNeeded()
    }

    // MARK: - Automatic continuation

    /// Starts preparing AudioMuse's continuation once the queue is nearly out.
    /// Suggestions are appended to the real queue for gapless playback, while
    /// `autoplayStartIndex` keeps them visually distinct.
    private func primeAutoplayIfNeeded() {
        guard continuePlayingSimilarMusic,
              repeatMode == .off,
              queue.indices.contains(currentIndex),
              AutoplayPriming.shouldPrime(
                currentIndex: currentIndex,
                queueCount: queue.count
              ),
              // The continuation follows on from the end of the queue rather
              // than from whatever is playing, so it stays coherent with what
              // the listener actually chose last.
              let seed = queue.last else { return }
        guard autoplayRequestSeedID != seed.id,
              autoplayExhaustedSeedID != seed.id else { return }

        autoplayRequestTask?.cancel()
        autoplayRequestSeedID = seed.id
        autoplayRequestTask = Task { [weak self] in
            guard let self else { return }
            do {
                let items = try await jellyfinService.fetchInstantMix(
                    itemId: seed.id,
                    limit: AutoplayPriming.requestSize
                )
                try Task.checkCancellation()
                let suggestions = items
                    .filter { $0.Type == .Audio }
                    .map { Track(from: $0, baseURL: self.jellyfinService.baseURL) }

                await MainActor.run { [weak self] in
                    self?.appendAutoplaySuggestions(suggestions, seedID: seed.id)
                }
            } catch is CancellationError {
                return
            } catch {
                logger.warning(
                    "Unable to prepare AudioMuse continuation for \(seed.id, privacy: .private(mask: .hash)): \(error.localizedDescription)"
                )
                await MainActor.run { [weak self] in
                    guard self?.autoplayRequestSeedID == seed.id else { return }
                    self?.autoplayRequestTask = nil
                    self?.autoplayRequestSeedID = nil
                }
            }
        }
    }

    private func appendAutoplaySuggestions(_ suggestions: [Track], seedID: String) {
        guard continuePlayingSimilarMusic,
              repeatMode == .off,
              autoplayRequestSeedID == seedID,
              queue.indices.contains(currentIndex),
              // The queue may have grown or been reordered while the request
              // was in flight; these only belong after the song they came from.
              queue.last?.id == seedID,
              AutoplayPriming.shouldPrime(
                currentIndex: currentIndex,
                queueCount: queue.count
              ) else {
            autoplayRequestTask = nil
            if autoplayRequestSeedID == seedID { autoplayRequestSeedID = nil }
            return
        }

        // Finished queue entries are history, not upcoming duplicates. An
        // AudioMuse continuation of a Daily Mix often overlaps that source
        // mix; excluding every historical item could discard the whole result.
        let unique = AutoplayPriming.batch(
            from: suggestions,
            excluding: Set(queue[currentIndex...].map(\.id))
        )
        guard !unique.isEmpty else {
            logger.info(
                "AudioMuse returned \(suggestions.count) continuation items for \(seedID, privacy: .private(mask: .hash)), but none were new relative to the current/upcoming queue"
            )
            autoplayRequestTask = nil
            autoplayRequestSeedID = nil
            autoplayExhaustedSeedID = seedID
            return
        }

        autoplayStartIndex = autoplayStartIndex ?? queue.count
        queue.append(contentsOf: unique)
        autoplayRequestTask = nil
        autoplayRequestSeedID = nil
        savePlaybackState()

        // The current player was created before these tracks existed. Extend
        // its short preload window in place so priming never interrupts or
        // seeks the final deliberately queued song.
        while playerItems.count < 3 {
            let nextIndex = currentIndex + playerItems.count
            guard queue.indices.contains(nextIndex),
                  let item = makeItem(for: queue[nextIndex]) else { break }
            engine?.append(item)
            playerItems.append(item)
        }
        updateNowPlayingInfo()
    }

    /// Explicit queue edits take precedence over an unplayed generated tail.
    private func discardUpcomingAutoplay() {
        autoplayRequestTask?.cancel()
        autoplayRequestTask = nil
        autoplayRequestSeedID = nil
        guard let start = autoplayStartIndex else { return }
        let removableStart = max(start, currentIndex + 1)
        if removableStart < queue.count {
            queue.removeSubrange(removableStart..<queue.endIndex)
        }
        autoplayStartIndex = nil

        // The engine is holding the preloaded successors. Remove those too,
        // otherwise a discarded suggestion could still start even though it no
        // longer appears in Up Next.
        if let engine, let currentItem = engine.currentItem {
            for item in playerItems where item !== currentItem {
                engine.remove(item)
            }
            playerItems = [currentItem]
        } else {
            playerItems.removeAll()
        }
    }

    private func cancelAutoplaySuggestions(removeUpcoming: Bool) {
        autoplayRequestTask?.cancel()
        autoplayRequestTask = nil
        autoplayRequestSeedID = nil
        // The queue is changing shape, so a seed that had nothing new to add
        // against the old one deserves another go.
        autoplayExhaustedSeedID = nil
        if removeUpcoming {
            discardUpcomingAutoplay()
        } else {
            autoplayStartIndex = nil
        }
    }

    // MARK: - Gapless Playback Setup

    /// Loads the current track and the two behind it, so each starts the moment
    /// the one before it ends.
    private func setupGaplessQueue(startingAt index: Int) {
        // Whatever was playing is finished with. Left running it would keep its
        // clock and its events coming in alongside the new queue's.
        engine?.shutDown()
        playerItems.removeAll()

        let engine = makeEngine()
        engine.onEvent = { [weak self] event in
            self?.handle(event)
        }
        self.engine = engine
        observedTrackID = nil
        observedTime = 0
        // These streams begin at the tracks' own beginnings, whatever the last
        // ones were cut from.
        streamStartOffset = 0

        logger.info("🎵 Setting up gapless queue starting at index \(index)")

        for (offset, track) in Array(queue[index...].prefix(3)).enumerated() {
            guard let item = makeItem(for: track) else {
                logger.error("❌ Failed to get playback URL for track at index \(index + offset): \(track.name)")
                continue
            }
            playerItems.append(item)
        }

        engine.load(playerItems)

        logger.info("✅ Gapless queue setup complete with \(self.playerItems.count) tracks loaded")
    }

    /// Handle track finishing in gapless mode
    private func handleTrackFinished(_ finishedItem: any PlaybackItemHandle) {
        // CRITICAL: Only process if this is the FIRST item in our queue
        // By the time this arrives, the engine has already advanced to the next item
        // So we check if the finished item WAS the first item (the one that should have been playing)
        guard let firstItem = playerItems.first, finishedItem === firstItem else {
            // This is either a preloaded item finishing early (shouldn't happen) or an old item
            logger.info("⏭️ Non-first item finished, ignoring (not our current track)")
            return
        }

        // Additional safety: only process if we're actually in a playing state
        guard isPlaying || engine?.rate != 0 else {
            logger.info("⏭️ Track finished but not playing, ignoring")
            return
        }

        // CRITICAL FIX: Verify we're actually near the end of the track
        // Sometimes AVPlayerItemDidPlayToEndTime fires incorrectly mid-song
        guard let currentTrack = currentTrack else {
            logger.warning("⚠️ Track finished but currentTrack is nil, ignoring")
            return
        }

        // Sometimes AVPlayerItemDidPlayToEndTime fires incorrectly mid-song, so
        // check how far the finished item itself actually got. Our own observed
        // time is no longer trustworthy here: the queue player has already moved
        // on, so the last sample may belong to the song now playing.
        guard TrackCompletion.isGenuine(
            itemPlayedTime: finishedItem.playedTime,
            itemDuration: finishedItem.loadedDuration,
            observedTime: self.currentTime,
            trackDuration: currentTrack.duration
        ) else {
            logger.warning("⚠️ IGNORING false 'track finished' notification for '\(currentTrack.name)'")
            logger.warning("   Item time: \(finishedItem.playedTime)s, observed: \(self.currentTime)s, duration: \(currentTrack.duration)s")
            return
        }

        logger.info("✅ Current track finished playing: \(currentTrack.name) (time: \(self.currentTime)s, duration: \(currentTrack.duration)s)")

        advanceAfterTrackEnded()
    }

    /// Moves the queue on to whatever the player is already playing, doing the
    /// bookkeeping (reporting, metadata, preloading) the advance implies.
    private func advanceAfterTrackEnded() {
        // Report stopped for the track that just finished
        stopProgressReporting(reportStopped: true)

        guard repeatMode != .one else {
            // The engine may already have advanced past (and dropped) the
            // finished item by the time this notification arrives. Rebuild the
            // current stream so repeat-one always starts from the real 0:00.
            pendingStart = nil
            playCurrentTrack()
            return
        }

        switch repeatMode {
        case .off:
            guard currentIndex < queue.count - 1 else {
                // End of queue
                dropFinishedItem()
                isPlaying = false
                return
            }
            adoptNextItem(at: currentIndex + 1)
        case .all:
            if currentIndex < queue.count - 1 {
                adoptNextItem(at: currentIndex + 1)
            } else {
                // Loop back to the beginning, which needs the whole window
                // reloaded rather than stepped.
                currentIndex = 0
                setupGaplessQueue(startingAt: 0)
                engine?.play()
                isPlaying = true
                updateNowPlayingInfo()
            }
        case .one:
            // Already handled above
            break
        }
    }

    /// What was playing is finished with, so what we hold starts at the item
    /// now playing.
    private func dropFinishedItem() {
        if !playerItems.isEmpty {
            playerItems.removeFirst()
        }
    }

    /// Takes the queue onto the item the engine has moved to: metadata,
    /// reporting, and one more track loaded behind it.
    private func adoptNextItem(at index: Int) {
        dropFinishedItem()

        guard queue.indices.contains(index) else {
            logger.error("❌ Index \(index) out of bounds for queue size \(self.queue.count)")
            updateNowPlayingInfo()
            return
        }

        currentIndex = index
        let newTrack = queue[index]
        let previousTrack: Track? = currentTrack
        recordPlaybackTransition(to: newTrack)
        currentTrack = newTrack
        currentTime = 0
        lastValidPlaybackTime = 0
        // This item is its own stream, playing from its own beginning.
        streamStartOffset = 0

        // Take it back to that beginning — a preloaded item can start
        // mid-buffer if the one before it was streamed.
        engine?.currentItem?.seek(to: 0, tolerance: 0)

        // Set duration from track metadata (not from stream)
        duration = newTrack.duration
        logger.info("📏 Track changed: '\(previousTrack?.name ?? "nil")' → '\(newTrack.name)' (index: \(self.currentIndex), duration: \(newTrack.duration)s)")

        startProgressReporting(for: newTrack)
        primeAutoplayIfNeeded()

        // Keep three loaded, so the track after this one is ready in time.
        let nextIndex = currentIndex + playerItems.count
        if nextIndex < queue.count {
            let nextTrack = queue[nextIndex]
            if let item = makeItem(for: nextTrack) {
                engine?.append(item)
                playerItems.append(item)
                logger.info("✅ Preloaded next track: \(nextTrack.name) at index \(nextIndex)")
            } else {
                logger.error("❌ Failed to preload next track: \(nextTrack.name)")
            }
        }

        updateNowPlayingInfo()
    }

    /// True while the queue player has moved on to an item the queue we track
    /// still treats as upcoming.
    private func playerHasOutrunQueue() -> Bool {
        guard let playing = engine?.currentItem, let expected = playerItems.first else { return false }
        return playing !== expected
    }

    /// Where the playing item sits among the ones we are holding, if at all.
    private func playingItemIndex() -> Int? {
        guard let playing = engine?.currentItem else { return nil }
        return playerItems.firstIndex { $0 === playing }
    }

    /// Moves the queue onto whatever is actually playing, in one step.
    ///
    /// Advancing a single position per observation assumes the player is exactly
    /// one ahead. When it is further ahead the queue never catches it, and each
    /// observation moves one more track, so the whole queue is consumed in a few
    /// seconds. Closing the gap in one go leaves the two in step.
    private func catchUpToPlayingItem() {
        guard let positions = StalledAdvanceRecovery.positionsToAdvance(
            playingIndex: playingItemIndex()
        ) else {
            // Playing something we are not holding. Advancing would be a guess,
            // and the guess is what does the damage.
            logger.error("⚠️ Player is on an item the queue does not hold; leaving the queue where it is")
            return
        }

        logger.warning("⚠️ Player is \(positions) track(s) ahead of the queue — catching up")
        for _ in 0..<positions {
            advanceAfterTrackEnded()
        }
    }

    // MARK: - Reacting to the engine

    /// Everything the engine reports arrives here.
    private func handle(_ event: PlaybackEngineEvent) {
        switch event {
        case .timeObserved(let itemTime):
            observeTime(itemTime)

        case .itemEnded(let item):
            handleTrackFinished(item)

        case .activityChanged(let activity):
            playbackActivityChanged(activity)

        case .itemReady(let item):
            guard item === engine?.currentItem else {
                logger.info("✅ Preloaded item ready")
                return
            }
            logger.info("✅ Player item ready to play (duration from track metadata: \(self.duration)s)")
            isBuffering = false
            // Streaming items can start mid-buffer, so a fresh track is taken
            // back to the beginning — but only now, because a seek before this
            // point is dropped.
            if pendingStartAtZero {
                pendingStartAtZero = false
                item.seek(to: 0, tolerance: 0)
            }

        case .itemFailed(let item, let error):
            logger.error("❌ Player item failed: \(error.localizedDescription)")
            if item === engine?.currentItem {
                handlePlaybackError(error)
            }

        case .bufferEmptied(let item):
            if item === engine?.currentItem {
                isBuffering = true
                logger.warning("⏸️ Buffer empty - playback may stall")
            }

        case .bufferRecovered(let item):
            if item === engine?.currentItem, isBuffering {
                logger.info("▶️ Buffer recovered - playback can resume")
                isBuffering = false
            }
        }
    }

    /// The track the position samples have been describing, and the last
    /// position taken from them. Kept beside the engine's own reading so a jump
    /// backwards can be told from a track change.
    private var observedTrackID: String?
    private var observedTime: Double = 0

    /// A position sample from the engine, by the playing item's own clock.
    private func observeTime(_ itemTime: TimeInterval) {
        // Don't update time during an active seek — let the seek completion handle it
        guard !isSeeking else { return }

        // The engine starts the next item before the end-of-item event lets us
        // move `currentTrack` with it. Samples taken in that window describe the
        // next song, so publishing them would put a stranger's position under
        // the current title — and would hide how far the finished track really
        // got from the completion check.
        if playerHasOutrunQueue() {
            mismatchedItemSamples += 1
            if StalledAdvanceRecovery.shouldForceAdvance(mismatchedSamples: mismatchedItemSamples) {
                mismatchedItemSamples = 0
                catchUpToPlayingItem()
            }
            return
        }
        mismatchedItemSamples = 0

        // Reset time tracking when the track changes, so the restart detector
        // does not read a new song's first sample as a jump. Done before the
        // position is read, or that first reading is still measured from where
        // the last song was seeked to.
        if let currentTrackId = currentTrack?.id, currentTrackId != observedTrackID {
            logger.info("🔄 Track changed in time observer, resetting time tracking (was: \(self.observedTrackID ?? "nil"), now: \(currentTrackId))")
            observedTime = 0
            observedTrackID = currentTrackId
            // A new song is owed its own attempts, whatever the last one did.
            restartRecoveryAttempts.removeAll()
        }

        // A stream asked to begin partway through counts from nothing, so where
        // it was cut is added back for the position to describe the track
        // rather than the stream.
        let newTime = streamStartOffset + itemTime

        // Sync with any external seek (e.g. the user seeking backward) so the
        // restart detector doesn't misread a legitimate seek as a stream restart
        observedTime = PlaybackRestartRecovery.synchronizedPreviousTime(
            observerTime: observedTime,
            authoritativeTime: lastValidPlaybackTime
        )

        // Detect a stream restarting on its own, within the same track.
        if PlaybackRestartRecovery.shouldRecover(
            newTime: newTime,
            previousTime: observedTime,
            trackedTrackID: observedTrackID,
            currentTrackID: currentTrack?.id,
            isSeeking: isSeeking,
            recentAttempts: restartRecoveryAttempts
        ) {
            logger.error("🚨 UNEXPECTED RESTART DETECTED: Time jumped from \(self.observedTime)s to \(newTime)s")
            logger.error("   Track: '\(self.currentTrack?.name ?? "unknown")'")

            if isPlaying {
                logger.info("🔧 Attempting to recover playback position...")
                let recoverTo = observedTime
                restartRecoveryAttempts.append(Date())
                seek(to: recoverTo)
            }
        }

        currentTime = newTime
        observedTime = newTime
        lastValidPlaybackTime = newTime

        // Duration comes from track metadata: a transcoded stream reports itself
        // as indefinite, so its own length says nothing.
        if let expectedDuration = currentTrack?.duration, duration != expectedDuration {
            duration = expectedDuration
            logger.info("📏 Duration sync: Updated to \(expectedDuration)s")
        }
    }


    private func cleanupPlayer() {
        // Stop progress reporting (don't double-report if handleTrackFinished already did)
        stopProgressReporting(reportStopped: lastReportedItemId != nil)

        engine?.shutDown()
        engine = nil
        playerItems.removeAll()

        // These describe a player that no longer exists.
        cancelStallWatch()
        pausedReconcileWorkItem?.cancel()
        pausedReconcileWorkItem = nil
        pendingStartAtZero = false
    }

    // MARK: - Playback Reporting

    private func positionTicks() -> Int64 {
        return Int64(currentTime * 10_000_000)
    }

    private func startProgressReporting(for track: Track) {
        stopProgressReporting()
        lastReportedItemId = track.id
        Task { await jellyfinService.reportPlaybackStart(itemId: track.id, positionTicks: positionTicks()) }
        progressReportTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            guard let self = self, let itemId = self.currentTrack?.id else { return }
            let ticks = self.positionTicks()
            let paused = !self.isPlaying
            Task { await self.jellyfinService.reportPlaybackProgress(itemId: itemId, positionTicks: ticks, isPaused: paused) }
        }
    }

    private func stopProgressReporting(reportStopped: Bool = true) {
        progressReportTimer?.invalidate()
        progressReportTimer = nil
        if reportStopped, let itemId = lastReportedItemId {
            let ticks = positionTicks()
            Task { await jellyfinService.reportPlaybackStopped(itemId: itemId, positionTicks: ticks) }
            lastReportedItemId = nil
        }
    }

    // MARK: - Now Playing & Remote Controls

    private func setupRemoteControls() {
        let commandCenter = MPRemoteCommandCenter.shared()

        // Remove any existing targets first
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)
        commandCenter.changePlaybackPositionCommand.removeTarget(nil)

        // Enable commands
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.isEnabled = true

        // Play/Pause
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.play()
            return .success
        }

        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }

        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }

        // Skip controls
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.playNext()
            return .success
        }

        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.playPrevious()
            return .success
        }

        // Seek controls
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            if let positionEvent = event as? MPChangePlaybackPositionCommandEvent {
                self?.seek(to: positionEvent.positionTime)
                return .success
            }
            return .commandFailed
        }

        // The Now Playing UI draws a single pair of side buttons, and skip
        // intervals take that slot ahead of track changes. A music player wants
        // previous/next there, so the skip commands stay off and scrubbing is
        // left to changePlaybackPositionCommand above.
        commandCenter.skipForwardCommand.removeTarget(nil)
        commandCenter.skipBackwardCommand.removeTarget(nil)
        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.skipBackwardCommand.isEnabled = false
    }

    func updateNowPlayingInfo() {
        guard let track = currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = track.name
        info[MPMediaItemPropertyArtist] = track.artistName
        info[MPMediaItemPropertyAlbumTitle] = track.albumName
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPMediaItemPropertyPlaybackDuration] = duration > 0 ? duration : 0
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0

        // Add media type
        info[MPMediaItemPropertyMediaType] = MPMediaType.music.rawValue

        let url = track.artworkURL.flatMap(URL.init(string:))

        // Carried across the update rather than left out and filled in after.
        // This runs on every play, pause, seek and position report, and the
        // lock screen draws whatever it is handed the moment it is handed it —
        // so omitting the artwork here is a grey card until the next write.
        if let artwork = artwork(for: track, url: url) {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        logger.info("🎵 Now Playing updated: \(track.name)")

        guard info[MPMediaItemPropertyArtwork] == nil, let url else { return }

        Task {
            guard let image = try? await ImageCache.shared.loadImage(from: url) else { return }
            await MainActor.run {
                guard self.currentTrack?.id == track.id else { return }
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self.nowPlayingArtwork = (track.id, artwork)

                if var currentInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo {
                    currentInfo[MPMediaItemPropertyArtwork] = artwork
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = currentInfo
                }
            }
        }
    }

    /// The lock screen's artwork for this track, if it can be had without
    /// waiting. Held onto because building it decodes the image, and this is
    /// asked several times a second while a song plays.
    private func artwork(for track: Track, url: URL?) -> MPMediaItemArtwork? {
        if let held = nowPlayingArtwork, held.trackID == track.id {
            return held.artwork
        }

        guard let url, let image = ImageCache.shared.cachedMemoryImage(for: url) else {
            return nil
        }

        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        nowPlayingArtwork = (track.id, artwork)
        return artwork
    }

    // MARK: - Error Handling

    // MARK: - Reconciling intent with the player

    /// The player is the authority on whether audio is coming out. `isPlaying`
    /// is only ever what was asked for, and nothing used to notice when the two
    /// came apart — a player that never started, or that stopped on its own,
    /// left the UI showing a pause button over silence and kept reporting
    /// progress to Jellyfin for the length of the track.
    private func playbackActivityChanged(_ activity: PlaybackActivity) {
        // Timer bookkeeping follows the activity itself; what to *do* about it
        // is `PlaybackReconciliation`'s call.
        switch activity {
        case .playing:
            cancelStallWatch()
            cancelPausedReconcile()
            if isStalled { isStalled = false }
        case .waitingToStart:
            cancelPausedReconcile()
        case .paused:
            cancelStallWatch()
        }

        switch reconciliationAction(for: activity) {
        case .none:
            break
        case .restorePlayingState:
            isPlaying = true
        case .markStalled:
            scheduleStallWatch()
        case .clearPlayingState:
            schedulePausedReconcile()
        }
    }

    /// Re-asked at every timer deadline, because the player may have moved on
    /// while the timer was waiting.
    private func reconciliationAction(
        for activity: PlaybackActivity? = nil
    ) -> PlaybackReconciliation.Action {
        guard let activity = activity ?? engine?.activity else { return .none }
        return PlaybackReconciliation.action(
            activity: activity,
            intendsToPlay: isPlaying,
            isReconfiguring: isReconfiguringPlayer
        )
    }

    /// A player that has been waiting to start for a while is reported as
    /// stalled, and one still waiting long after that is treated as failed.
    private func scheduleStallWatch() {
        guard stallWorkItem == nil else { return }

        let notice = DispatchWorkItem { [weak self] in
            guard let self, self.reconciliationAction() == .markStalled else { return }
            if !self.isStalled { self.isStalled = true }
            self.logger.warning("⏳ Playback has been waiting to start for \(Int(self.stallNoticeDelay))s")
        }
        stallWorkItem = notice
        DispatchQueue.main.asyncAfter(deadline: .now() + stallNoticeDelay, execute: notice)

        DispatchQueue.main.asyncAfter(deadline: .now() + stallFailureDelay) { [weak self] in
            guard let self, self.reconciliationAction() == .markStalled else { return }
            self.logger.error("❌ Playback never started after \(Int(self.stallFailureDelay))s; giving up")
            self.isStalled = false
            self.handlePlaybackError(
                NSError(
                    domain: "PlayerManager",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Playback could not start. Check your connection and try again."]
                )
            )
        }
    }

    private func cancelStallWatch() {
        stallWorkItem?.cancel()
        stallWorkItem = nil
    }

    private func cancelPausedReconcile() {
        pausedReconcileWorkItem?.cancel()
        pausedReconcileWorkItem = nil
    }

    /// Every deliberate pause — the pause button, a track change, teardown —
    /// also drives the status to `.paused`, so this waits to see whether the
    /// player is still stopped once the transition has had time to finish.
    private func schedulePausedReconcile() {
        cancelPausedReconcile()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pausedReconcileWorkItem = nil
            guard self.reconciliationAction() == .clearPlayingState else { return }

            self.logger.warning("⚠️ Player stopped on its own — clearing the playing state")
            self.isPlaying = false
            self.isStalled = false
            // Jellyfin was being told this track was playing; it is not.
            self.stopProgressReporting(reportStopped: true)
            self.updateNowPlayingInfo()
        }
        pausedReconcileWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + pausedReconcileDelay, execute: item)
    }

    private func handlePlaybackError(_ error: Error?) {
        let errorDescription = error?.localizedDescription ?? "Playback failed"
        errorMessage = errorDescription
        isPlaying = false
        isStalled = false
        cancelStallWatch()
        // Nothing is playing, so Jellyfin should stop being told otherwise.
        stopProgressReporting(reportStopped: true)

        logger.error("Playback Error: \(errorDescription)")
        if let error = error {
            logger.error("Error details: \(error)")
        }

        // Retry logic for network errors
        if let nsError = error as NSError? {
            switch nsError.code {
            case -1004, -1009: // Cannot connect to host, no internet
                logger.info("Network error detected, will retry in 2 seconds")
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    self?.playCurrentTrack()
                }
            default:
                break
            }
        }
    }

    // MARK: - Notifications

    private func setupNotifications() {
        // Audio interruption handling
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .sink { [weak self] notification in
                guard let info = notification.userInfo,
                      let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

                switch type {
                case .began:
                    self?.engine?.pause()
                    self?.isPlaying = false
                case .ended:
                    // Re-activate audio session and resume playback
                    do {
                        try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
                        if let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt,
                           AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume) {
                            self?.engine?.play()
                            self?.isPlaying = true
                        }
                    } catch {
                        self?.logger.error("Failed to reactivate audio session: \(error)")
                    }
                @unknown default:
                    break
                }
            }
            .store(in: &cancellables)

        // Route change handling (e.g., headphones disconnected)
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .sink { [weak self] notification in
                guard let info = notification.userInfo,
                      let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

                switch reason {
                case .oldDeviceUnavailable:
                    // Headphones were unplugged, pause playback
                    self?.engine?.pause()
                    self?.isPlaying = false
                case .categoryChange:
                    // Re-configure audio session if category changed
                    self?.configureAudioSession()
                default:
                    break
                }
            }
            .store(in: &cancellables)

        // App lifecycle notifications
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in
                // App is going to background - ensure playback continues
                self?.updateNowPlayingInfo()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                guard let self = self else { return }
                // App entered background - ensure audio session is still active
                do {
                    try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
                    self.updateNowPlayingInfo()
                    self.logger.info("🔵 Maintained audio session in background")
                } catch {
                    self.logger.error("Failed to maintain audio session in background: \(error)")
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                // App returning to foreground - reactivate audio session
                do {
                    try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
                } catch {
                    self?.logger.error("Failed to reactivate audio session: \(error)")
                }
            }
            .store(in: &cancellables)
    }
}
