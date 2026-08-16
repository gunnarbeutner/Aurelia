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
/// AVQueuePlayer starts the next item before the notification reaches us, so by
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
enum StalledAdvanceRecovery {
    /// Time observer samples (half a second apart) to tolerate before forcing
    /// the queue back into step with what is actually playing.
    static let requiredMismatchedSamples = 3

    static func shouldForceAdvance(mismatchedSamples: Int) -> Bool {
        mismatchedSamples >= requiredMismatchedSamples
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
        status: AVPlayer.TimeControlStatus,
        intendsToPlay: Bool,
        isReconfiguring: Bool
    ) -> Action {
        // A player being torn down and rebuilt passes through every status on
        // the way, and none of it describes what the listener wants.
        guard !isReconfiguring else { return .none }

        switch status {
        case .playing:
            return intendsToPlay ? .none : .restorePlayingState
        case .waitingToPlayAtSpecifiedRate:
            return intendsToPlay ? .markStalled : .none
        case .paused:
            return intendsToPlay ? .clearPlayingState : .none
        @unknown default:
            return .none
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
                player?.rate = playbackRate
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
    private var player: AVQueuePlayer?
    private var playerItems: [AVPlayerItem] = []
    private var timeObserver: Any?
    private var progressReportTimer: Timer?
    private var lastReportedItemId: String?
    private var cancellables = Set<AnyCancellable>()
    private var playerItemCancellables = Set<AnyCancellable>() // Separate for player item observers
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

    /// Get playback URL respecting user's streaming quality preference
    private func playbackURL(for track: Track) -> URL? {
        // Check offline first
        if let localURL = downloadManager.getLocalURL(for: track.id) {
            return localURL
        }
        let qualityRaw = UserDefaults.standard.string(forKey: "streamingQuality") ?? "medium"
        let quality = StreamingQuality(rawValue: qualityRaw) ?? .medium
        if quality == .original {
            return jellyfinService.getDownloadURL(for: track.id)
        } else {
            return jellyfinService.getStreamingURL(for: track.id, bitrate: quality.bitrate)
        }
    }
    private let downloadManager = DownloadManager.shared
    /// When this track was last pulled back to where it had got to.
    private var restartRecoveryAttempts: [Date] = []
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

    override init() {
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
        pendingSeekTime = savedTime

        logger.info("▶️ Restored state: \(self.currentTrack?.name ?? "none") @ \(savedTime)s (queue: \(savedQueue.count) tracks)")
        return true
    }

    /// Pending seek time — applied when playback starts after state restore
    private var pendingSeekTime: Double = 0

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
        pendingSeekTime = 0  // Fresh tap — always start from beginning
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
        pendingSeekTime = 0  // Fresh tap — always start from beginning
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
        guard let player = player else {
            if currentTrack != nil {
                playCurrentTrack()
            }
            return
        }

        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }

        updateNowPlayingInfo()
    }

    /// Resume playback
    func play() {
        guard let player = player else {
            if currentTrack != nil {
                playCurrentTrack()
            }
            return
        }

        player.play()
        isPlaying = true
        updateNowPlayingInfo()
        if let itemId = currentTrack?.id {
            let ticks = positionTicks()
            Task { await jellyfinService.reportPlaybackProgress(itemId: itemId, positionTicks: ticks, isPaused: false) }
        }
    }

    /// Pause playback
    func pause() {
        player?.pause()
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

        currentIndex = nextIndex
        // Manually advance and rebuild gapless queue
        player?.pause()
        playCurrentTrack()
    }

    /// Skips to previous track
    func playPrevious() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()

        // If more than 3 seconds into track, restart it
        if currentTime > 3 {
            seek(to: 0)
        } else if currentIndex > 0 {
            currentIndex -= 1
            // Rebuild gapless queue from new position
            player?.pause()
            playCurrentTrack()
        } else {
            // At beginning, just restart current track
            seek(to: 0)
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
        guard let player = player else {
            logger.error("❌ Cannot seek - player is nil")
            return
        }

        guard let currentItem = player.currentItem else {
            logger.error("❌ Cannot seek - no current item")
            return
        }

        // Log seeks to beginning to help debug restarts
        if time == 0 {
            logger.info("🔄 Seeking to beginning of track: \(self.currentTrack?.name ?? "unknown")")
        }

        // Check if current item is ready to seek
        guard currentItem.status == .readyToPlay else {
            logger.warning("⚠️ Cannot seek - item not ready (status: \(currentItem.status.rawValue))")
            return
        }

        // Duration comes from track metadata (set when track starts playing)
        guard duration > 0 else {
            logger.error("❌ Cannot seek - duration is 0 (track metadata issue)")
            return
        }

        // Clamp time to valid range
        let clampedTime = max(0, min(time, duration))
        let cmTime = CMTime(seconds: clampedTime, preferredTimescale: 600)

        logger.info("🔍 Seeking to \(clampedTime)s (duration: \(self.duration)s)")

        // Mark seeking so the time observer/restart detector don't fight us
        isSeeking = true
        // Update currentTime immediately to prevent UI snapping back
        self.currentTime = clampedTime

        // Seek the current item directly (more reliable than player.seek on AVQueuePlayer)
        let tolerance = CMTime(seconds: 0.3, preferredTimescale: 600)
        let targetItem = player.currentItem ?? playerItems.first
        targetItem?.seek(to: cmTime, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] completed in
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
        player?.rate = isPlaying ? rate : 0
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
                player?.pause()
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
                player?.play()
            }
        } else {
            // Removing track after current - just remove
            queue.remove(at: index)
            // If it's in the preloaded buffer, rebuild gapless queue
            let bufferEnd = currentIndex + playerItems.count
            if index < bufferEnd && isPlaying {
                setupGaplessQueue(startingAt: currentIndex)
                player?.play()
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

        // If we're currently playing, we need to sync the AVQueuePlayer with the new order
        // BUT we cannot restart the current track
        if isPlaying && player != nil {
            // Remove all preloaded items (keep only the currently playing one)
            while playerItems.count > 1 {
                playerItems.removeLast()
                // Remove from AVQueuePlayer (can't remove specific items, so we rely on them being at the end)
            }

            // Now preload the next tracks based on the NEW queue order
            for offset in 1...2 {
                let nextIndex = currentIndex + offset
                guard nextIndex < queue.count else { break }

                let nextTrack = queue[nextIndex]
                guard let url = playbackURL(for: nextTrack) else {
                    logger.error("❌ Failed to preload track at index \(nextIndex): \(nextTrack.name)")
                    continue
                }

                let playerItem = AVPlayerItem(url: url)
                playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = true
                playerItem.preferredForwardBufferDuration = 15.0

                player?.insert(playerItem, after: nil)
                playerItems.append(playerItem)
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
        player?.pause()
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

        // Keep the current AVPlayerItem and remove only its preloaded successors.
        if let player, let currentItem = player.currentItem {
            for item in playerItems where item !== currentItem {
                player.remove(item)
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
        currentIndex = index
        playCurrentTrack()
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

        // Setup AVQueuePlayer with current + next 2 tracks for gapless playback
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
        player?.play()
        isPlaying = true

        // Report playback start to Jellyfin
        startProgressReporting(for: track)


        // Apply pending seek ONLY for state-restore resume (pendingSeekTime is set by restorePlaybackState).
        // play(_ track:) and play(tracks:) clear this to 0 so fresh taps always start from beginning.
        if pendingSeekTime > 1.0 {
            let seekTo = pendingSeekTime
            pendingSeekTime = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.seek(to: seekTo)
            }
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
                  let url = playbackURL(for: queue[nextIndex]) else { break }
            let item = AVPlayerItem(url: url)
            item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
            item.preferredForwardBufferDuration = 15
            player?.insert(item, after: nil)
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

        // AVQueuePlayer owns its own copies of preloaded successors. Remove
        // those too, otherwise a discarded suggestion could still start even
        // though it no longer appears in Up Next.
        if let player, let currentItem = player.currentItem {
            for item in playerItems where item !== currentItem {
                player.remove(item)
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

    /// Setup AVQueuePlayer for gapless playback
    private func setupGaplessQueue(startingAt index: Int) {
        // Clear old player items
        playerItems.removeAll()

        // Create player items for current + next 2 tracks (3 total for gapless playback)
        let tracksToLoad = Array(queue[index...].prefix(3))
        logger.info("🎵 Setting up gapless queue starting at index \(index)")

        for (offset, track) in tracksToLoad.enumerated() {
            let isOffline = downloadManager.getLocalURL(for: track.id) != nil

            guard let url = self.playbackURL(for: track) else {
                logger.error("❌ Failed to get playback URL for track at index \(index + offset): \(track.name)")
                continue
            }

            logger.info("  [\(offset)] \(isOffline ? "Offline" : "Streaming"): \(track.name)")

            let playerItem = AVPlayerItem(url: url)

            // Configure for reliable streaming playback
            if !isOffline {
                playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = true
                // Keep buffer reasonable — 60s caused preloaded items to start mid-stream
                playerItem.preferredForwardBufferDuration = 15.0
            }

            playerItems.append(playerItem)
        }

        // Create AVQueuePlayer with preloaded items
        player = AVQueuePlayer(items: playerItems)
        player?.automaticallyWaitsToMinimizeStalling = true
        player?.volume = 1.0

        // Setup observers for all items
        setupPlayerObservers()

        logger.info("✅ Gapless queue setup complete with \(self.playerItems.count) tracks loaded")
    }

    /// Handle track finishing in gapless mode
    private func handleTrackFinishedGapless(_ notification: Notification) {
        // Verify this is one of our player items
        guard let finishedItem = notification.object as? AVPlayerItem else {
            return
        }

        // CRITICAL: Only process if this is the FIRST item in our queue
        // By the time this notification fires, AVQueuePlayer has already advanced to the next item
        // So we check if the finished item WAS the first item (the one that should have been playing)
        guard let firstItem = playerItems.first, finishedItem == firstItem else {
            // This is either a preloaded item finishing early (shouldn't happen) or an old item
            logger.info("⏭️ Non-first item finished, ignoring (not our current track)")
            return
        }

        // Additional safety: only process if we're actually in a playing state
        guard isPlaying || player?.rate != 0 else {
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
            itemPlayedTime: finishedItem.currentTime().seconds,
            itemDuration: finishedItem.duration.seconds,
            observedTime: self.currentTime,
            trackDuration: currentTrack.duration
        ) else {
            logger.warning("⚠️ IGNORING false 'track finished' notification for '\(currentTrack.name)'")
            logger.warning("   Item time: \(finishedItem.currentTime().seconds)s, observed: \(self.currentTime)s, duration: \(currentTrack.duration)s")
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
            // AVQueuePlayer may already have advanced past (and removed) the
            // finished item by the time this notification arrives. Rebuild the
            // current stream so repeat-one always starts from the real 0:00.
            pendingSeekTime = 0
            playCurrentTrack()
            return
        }

        // Move to next track in queue
        if !playerItems.isEmpty {
            playerItems.removeFirst()
        }

        // Update current index and track
        switch repeatMode {
        case .off:
            guard currentIndex < queue.count - 1 else {
                // End of queue
                isPlaying = false
                return
            }
            currentIndex += 1
        case .all:
            // Loop to beginning if at end
            if currentIndex < queue.count - 1 {
                currentIndex += 1
            } else {
                currentIndex = 0
                // Reload queue from beginning for repeat all
                setupGaplessQueue(startingAt: 0)
                player?.play()
                isPlaying = true
                updateNowPlayingInfo()
                return
            }
        case .one:
            // Already handled above
            break
        }

        // Update current track and metadata
        if currentIndex < queue.count {
            let newTrack = queue[currentIndex]
            let previousTrack: Track? = currentTrack
            recordPlaybackTransition(to: newTrack)
            self.currentTrack = newTrack
            self.currentTime = 0
            self.lastValidPlaybackTime = 0

            // Seek next item to beginning — AVQueuePlayer preloads items and they
            // can start mid-buffer if the previous item was transcoded/streaming
            if let nextItem = player?.currentItem {
                let zero = CMTime(seconds: 0, preferredTimescale: 600)
                nextItem.seek(to: zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
            }

            // Set duration from track metadata (not from stream)
            duration = newTrack.duration
            logger.info("📏 Track changed: '\(previousTrack?.name ?? "nil")' → '\(newTrack.name)' (index: \(self.currentIndex), duration: \(newTrack.duration)s)")

            // Report playback start for the new track (gapless advance)
            startProgressReporting(for: newTrack)
            primeAutoplayIfNeeded()
        } else {
            logger.error("❌ currentIndex \(self.currentIndex) out of bounds for queue size \(self.queue.count)")
        }

        // Preload next track if available (maintain 3-track buffer)
        let nextIndex = currentIndex + playerItems.count
        logger.info("🔄 Preload check: currentIndex=\(self.currentIndex), playerItems.count=\(self.playerItems.count), nextIndex=\(nextIndex), queue.count=\(self.queue.count)")

        if nextIndex < queue.count {
            let nextTrack = queue[nextIndex]

            guard let url = playbackURL(for: nextTrack) else {
                logger.error("❌ Failed to preload next track: \(nextTrack.name)")
                updateNowPlayingInfo()
                return
            }

            let playerItem = AVPlayerItem(url: url)
            playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = true
            playerItem.preferredForwardBufferDuration = 15.0

            player?.insert(playerItem, after: nil)
            playerItems.append(playerItem)

            logger.info("✅ Preloaded next track: \(nextTrack.name) at index \(nextIndex)")
        }

        updateNowPlayingInfo()
    }

    /// True while the queue player has moved on to an item the queue we track
    /// still treats as upcoming.
    private func playerHasOutrunQueue() -> Bool {
        guard let playing = player?.currentItem, let expected = playerItems.first else { return false }
        return playing !== expected
    }

    private func setupPlayerObservers() {
        guard let player = player else {
            logger.error("Player is nil in setupPlayerObservers")
            errorMessage = "Failed to setup player"
            return
        }

        // Clear only player item observers (not notification observers)
        playerItemCancellables.removeAll()

        // The player's own view of whether audio is coming out. Everything else
        // here describes an item; this describes playback.
        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.timeControlStatusChanged(status)
            }
            .store(in: &playerItemCancellables)

        // Observe playback time - tracks current item automatically
        let interval = CMTime(seconds: 0.5, preferredTimescale: 1000)
        var lastValidTime: Double = 0.0
        var lastTrackedTrackId: String? = nil

        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            guard time.isValid && time.isNumeric else { return }

            // Don't update time during an active seek — let the seek completion handle it
            guard !self.isSeeking else { return }

            // The queue player starts the next item before the end-of-item
            // notification lets us move `currentTrack` with it. Samples taken in
            // that window describe the next song, so publishing them would put a
            // stranger's position under the current title — and would hide how
            // far the finished track really got from the completion check.
            if self.playerHasOutrunQueue() {
                self.mismatchedItemSamples += 1
                if StalledAdvanceRecovery.shouldForceAdvance(mismatchedSamples: self.mismatchedItemSamples) {
                    self.logger.warning("⚠️ Player is playing ahead of the queue — advancing to catch up")
                    self.mismatchedItemSamples = 0
                    self.advanceAfterTrackEnded()
                }
                return
            }
            self.mismatchedItemSamples = 0

            let newTime = time.seconds

            // CRITICAL: Reset time tracking when track changes
            // This prevents false "restart" detection when AVQueuePlayer advances to next track
            if let currentTrackId = self.currentTrack?.id, currentTrackId != lastTrackedTrackId {
                self.logger.info("🔄 Track changed in time observer, resetting time tracking (was: \(lastTrackedTrackId ?? "nil"), now: \(currentTrackId))")
                lastValidTime = 0.0
                lastTrackedTrackId = currentTrackId
                // A new song is owed its own attempts, whatever the last one did.
                self.restartRecoveryAttempts.removeAll()
            }

            // Sync local tracker with any external seek (e.g. user seeking backward)
            // so the restart detector doesn't misread a legitimate seek as a stream restart
            lastValidTime = PlaybackRestartRecovery.synchronizedPreviousTime(
                observerTime: lastValidTime,
                authoritativeTime: self.lastValidPlaybackTime
            )

            // Detect unexpected stream restarts WITHIN THE SAME TRACK.
            // Only trigger if: not currently seeking, jumped back 30+ seconds (not a user seek),
            // was well into the track (>60s), and it's the same track.
            // Tightened from 10s to 30s to avoid fighting legitimate user seeks.
            if PlaybackRestartRecovery.shouldRecover(
                newTime: newTime,
                previousTime: lastValidTime,
                trackedTrackID: lastTrackedTrackId,
                currentTrackID: self.currentTrack?.id,
                isSeeking: self.isSeeking,
                recentAttempts: self.restartRecoveryAttempts
            ) {
                self.logger.error("🚨 UNEXPECTED RESTART DETECTED: Time jumped from \(lastValidTime)s to \(newTime)s")
                self.logger.error("   Track: '\(self.currentTrack?.name ?? "unknown")'")
                self.logger.error("   This indicates the AVPlayer stream restarted on its own")

                // Attempt recovery: seek back to where we were
                if self.isPlaying {
                    self.logger.info("🔧 Attempting to recover playback position...")
                    self.restartRecoveryAttempts.append(Date())
                    self.seek(to: lastValidTime)
                }
            }

            // Update current time from player
            self.currentTime = newTime
            lastValidTime = newTime
            self.lastValidPlaybackTime = newTime

            // Ensure duration matches current track (safeguard against race conditions)
            if let currentTrack = self.currentTrack, self.duration != currentTrack.duration {
                self.duration = currentTrack.duration
                self.logger.info("📏 Duration sync: Updated to \(currentTrack.duration)s for '\(currentTrack.name)'")
            }

            // Duration comes from Track metadata, not from stream
            // HTTP transcoded streams report isIndefinite, so we use Jellyfin API metadata
        }

        // Observe ALL player items in the queue
        for (index, playerItem) in playerItems.enumerated() {
            // Observe status
            playerItem.publisher(for: \.status)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] status in
                    guard let self = self else { return }

                    switch status {
                    case .readyToPlay:
                        if playerItem == self.player?.currentItem {
                            self.logger.info("✅ Player item ready to play (duration from track metadata: \(self.duration)s)")
                            self.isBuffering = false
                            // Streaming items can start mid-buffer, so a fresh
                            // track is taken back to the beginning — but only
                            // now, because a seek before this point is dropped.
                            if self.pendingStartAtZero {
                                self.pendingStartAtZero = false
                                playerItem.seek(
                                    to: CMTime(seconds: 0, preferredTimescale: 600),
                                    toleranceBefore: .zero,
                                    toleranceAfter: .zero
                                ) { _ in }
                            }
                        } else {
                            self.logger.info("✅ Preloaded item \(index) ready")
                        }
                    case .failed:
                        let error = playerItem.error ?? NSError(domain: "PlayerManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown playback error"])
                        self.logger.error("❌ Player item \(index) failed: \(error.localizedDescription)")
                        if playerItem == self.player?.currentItem {
                            self.handlePlaybackError(error)
                        }
                    case .unknown:
                        break
                    @unknown default:
                        break
                    }
                }
                .store(in: &playerItemCancellables)

            // Observe buffering for current item
            playerItem.publisher(for: \.isPlaybackBufferEmpty)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] isEmpty in
                    guard let self = self else { return }
                    // Only update buffering state if this is the current item
                    if playerItem == self.player?.currentItem {
                        self.isBuffering = isEmpty
                        if isEmpty {
                            self.logger.warning("⏸️ Buffer empty - playback may stall")
                        }
                    }
                }
                .store(in: &playerItemCancellables)

            // Observe likely to keep up
            playerItem.publisher(for: \.isPlaybackLikelyToKeepUp)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] isLikely in
                    guard let self = self else { return }
                    if playerItem == self.player?.currentItem {
                        if isLikely && self.isBuffering {
                            self.logger.info("▶️ Buffer recovered - playback can resume")
                            self.isBuffering = false
                        }
                    }
                }
                .store(in: &playerItemCancellables)

            // Observe playback stalls
            playerItem.publisher(for: \.isPlaybackBufferFull)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] isFull in
                    guard let self = self else { return }
                    if playerItem == self.player?.currentItem && isFull {
                        self.logger.info("📦 Playback buffer is full - good streaming health")
                    }
                }
                .store(in: &playerItemCancellables)
        }
    }

    private func cleanupPlayer() {
        if let timeObserver = timeObserver {
            player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }

        // Stop progress reporting (don't double-report if handleTrackFinished already did)
        stopProgressReporting(reportStopped: lastReportedItemId != nil)

        player?.pause()
        player = nil
        playerItemCancellables.removeAll()

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

        // Set Now Playing info immediately
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        logger.info("🎵 Now Playing updated: \(track.name)")

        // Add artwork if available
        if let artworkURL = track.artworkURL,
           let url = URL(string: artworkURL) {
            Task {
                do {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    if let image = UIImage(data: data) {
                        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }

                        await MainActor.run {
                            if var currentInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo,
                               currentInfo[MPMediaItemPropertyTitle] as? String == track.name {
                                currentInfo[MPMediaItemPropertyArtwork] = artwork
                                MPNowPlayingInfoCenter.default().nowPlayingInfo = currentInfo
                            }
                        }
                    }
                } catch {
                    logger.error("Failed to load artwork: \(error)")
                }
            }
        }
    }

    // MARK: - Error Handling

    // MARK: - Reconciling intent with the player

    /// The player is the authority on whether audio is coming out. `isPlaying`
    /// is only ever what was asked for, and nothing used to notice when the two
    /// came apart — a player that never started, or that stopped on its own,
    /// left the UI showing a pause button over silence and kept reporting
    /// progress to Jellyfin for the length of the track.
    private func timeControlStatusChanged(_ status: AVPlayer.TimeControlStatus) {
        // Timer bookkeeping follows the status itself; what to *do* about the
        // status is `PlaybackReconciliation`'s call.
        switch status {
        case .playing:
            cancelStallWatch()
            cancelPausedReconcile()
            if isStalled { isStalled = false }
        case .waitingToPlayAtSpecifiedRate:
            cancelPausedReconcile()
        case .paused:
            cancelStallWatch()
        @unknown default:
            break
        }

        switch reconciliationAction(for: status) {
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
        for status: AVPlayer.TimeControlStatus? = nil
    ) -> PlaybackReconciliation.Action {
        guard let status = status ?? player?.timeControlStatus else { return .none }
        return PlaybackReconciliation.action(
            status: status,
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
        // CRITICAL: Track endings for gapless playback
        // This observer is set up ONCE and persists for the lifetime of PlayerManager
        // AVFoundation posts this off the main thread, and the handler publishes
        // the new track to the UI, so hop before touching any of that state.
        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleTrackFinishedGapless(notification)
            }
            .store(in: &cancellables)

        // Audio interruption handling
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
            .sink { [weak self] notification in
                guard let info = notification.userInfo,
                      let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

                switch type {
                case .began:
                    self?.player?.pause()
                    self?.isPlaying = false
                case .ended:
                    // Re-activate audio session and resume playback
                    do {
                        try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
                        if let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt,
                           AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume) {
                            self?.player?.play()
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
                    self?.player?.pause()
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
