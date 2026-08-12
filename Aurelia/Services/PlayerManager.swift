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

    static func shouldRecover(
        newTime: Double,
        previousTime: Double,
        trackedTrackID: String?,
        currentTrackID: String?,
        isSeeking: Bool
    ) -> Bool {
        !isSeeking
            && newTime < previousTime - 30
            && previousTime > 60
            && trackedTrackID == currentTrackID
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
    private var isSeeking = false
    @Published var errorMessage: String?

    // MARK: - Playback Queue
    @Published var queue: [Track] = []
    @Published var currentIndex: Int = 0
    @Published var shuffleEnabled = false
    @Published var repeatMode: RepeatMode = .off
    @Published var playbackRate: Float = 1.0
    @Published var continuePlayingSimilarMusic = false {
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
    private var originalQueue: [Track] = []
    private var originalIndex: Int = 0
    private var lastValidPlaybackTime: Double = 0.0  // Track last known position to detect unexpected restarts
    private let statePersistenceQueue = DispatchQueue(
        label: "de.beutner.Aurelia.player-state-persistence",
        qos: .utility
    )
    private var autoplayRequestTask: Task<Void, Never>?
    private var autoplayRequestSeedID: String?

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
        continuePlayingSimilarMusic = UserDefaults.standard.bool(
            forKey: StateKey.continuePlayingSimilarMusic
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
        if recentlyPlayedTracks.count > 20 {
            recentlyPlayedTracks = Array(recentlyPlayedTracks.prefix(20))
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
        let tracks = await LibraryRepository.shared.cachedRecentTracks(in: scope, limit: 20)
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

        // Clean up previous player
        cleanupPlayer()

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

        // Seek first item to zero — streaming items can start mid-buffer if previously buffered
        if let firstItem = player?.currentItem {
            let zero = CMTime(seconds: 0, preferredTimescale: 600)
            firstItem.seek(to: zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in }
        }

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
        primeAutoplayIfNeeded()
    }

    // MARK: - Automatic continuation

    /// Starts preparing AudioMuse's continuation as soon as the final queued
    /// song begins. Suggestions are appended to the real queue for gapless
    /// playback, while `autoplayStartIndex` keeps them visually distinct.
    private func primeAutoplayIfNeeded() {
        guard continuePlayingSimilarMusic,
              repeatMode == .off,
              queue.indices.contains(currentIndex),
              currentIndex == queue.count - 1 else { return }

        let seed = queue[currentIndex]
        guard autoplayRequestSeedID != seed.id else { return }

        autoplayRequestTask?.cancel()
        autoplayRequestSeedID = seed.id
        autoplayRequestTask = Task { [weak self] in
            guard let self else { return }
            do {
                let items = try await jellyfinService.fetchInstantMix(itemId: seed.id, limit: 25)
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
              queue[currentIndex].id == seedID,
              currentIndex == queue.count - 1 else {
            autoplayRequestTask = nil
            if autoplayRequestSeedID == seedID { autoplayRequestSeedID = nil }
            return
        }

        let existingIDs = Set(queue.map(\.id))
        var seen = existingIDs
        let unique = suggestions.filter { track in
            guard !seen.contains(track.id) else { return false }
            seen.insert(track.id)
            return true
        }
        guard !unique.isEmpty else {
            autoplayRequestTask = nil
            autoplayRequestSeedID = nil
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

        // Use a wider window (10s) to account for time observer lag and metadata inaccuracies.
        // Jellyfin duration metadata can be off by several seconds vs actual stream length.
        let timeRemaining = currentTrack.duration - self.currentTime
        if timeRemaining > 10.0 {
            // More than 10s from the end — almost certainly a false notification
            logger.warning("⚠️ IGNORING false 'track finished' notification - still \(timeRemaining)s remaining in '\(currentTrack.name)'")
            logger.warning("   Current time: \(self.currentTime)s, Duration: \(currentTrack.duration)s")
            return
        }

        logger.info("✅ Current track finished playing: \(currentTrack.name) (time: \(self.currentTime)s, duration: \(currentTrack.duration)s)")

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

    private func setupPlayerObservers() {
        guard let player = player else {
            logger.error("Player is nil in setupPlayerObservers")
            errorMessage = "Failed to setup player"
            return
        }

        // Clear only player item observers (not notification observers)
        playerItemCancellables.removeAll()

        // Observe playback time - tracks current item automatically
        let interval = CMTime(seconds: 0.5, preferredTimescale: 1000)
        var lastValidTime: Double = 0.0
        var lastTrackedTrackId: String? = nil

        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            guard time.isValid && time.isNumeric else { return }

            // Don't update time during an active seek — let the seek completion handle it
            guard !self.isSeeking else { return }

            let newTime = time.seconds

            // CRITICAL: Reset time tracking when track changes
            // This prevents false "restart" detection when AVQueuePlayer advances to next track
            if let currentTrackId = self.currentTrack?.id, currentTrackId != lastTrackedTrackId {
                self.logger.info("🔄 Track changed in time observer, resetting time tracking (was: \(lastTrackedTrackId ?? "nil"), now: \(currentTrackId))")
                lastValidTime = 0.0
                lastTrackedTrackId = currentTrackId
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
                isSeeking: self.isSeeking
            ) {
                self.logger.error("🚨 UNEXPECTED RESTART DETECTED: Time jumped from \(lastValidTime)s to \(newTime)s")
                self.logger.error("   Track: '\(self.currentTrack?.name ?? "unknown")'")
                self.logger.error("   This indicates the AVPlayer stream restarted on its own")

                // Attempt recovery: seek back to where we were
                if self.isPlaying {
                    self.logger.info("🔧 Attempting to recover playback position...")
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

    private func handlePlaybackError(_ error: Error?) {
        let errorDescription = error?.localizedDescription ?? "Playback failed"
        errorMessage = errorDescription
        isPlaying = false

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
        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
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
