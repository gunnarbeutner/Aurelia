//
//  PlaybackEngine.swift
//  Aurelia
//
//  The audio engine the player talks to, and the AVFoundation one it uses.
//
//  Everything AVFoundation is reached through here: loading a queue, moving
//  within an item, and the four things the player needs to hear back — the
//  clock, an item ending, an item becoming ready or failing, and whether audio
//  is actually coming out. Keeping that behind a protocol means the player's
//  reactions to those events can be exercised without an audio device, which is
//  where its harder bugs have lived: a queue that walked itself when the engine
//  ran ahead, a position that survived into the next song, a seek that moved
//  the clock but not the audio.
//

import AVFoundation
import Combine
import Foundation

/// Whether audio is coming out, as opposed to whether it was asked for.
enum PlaybackActivity: Equatable {
    case paused
    /// Trying to start: buffering, or waiting on the network.
    case waitingToStart
    case playing
}

/// One loaded track the engine can play.
protocol PlaybackItemHandle: AnyObject {
    /// Where it is read from. A local file and the original-quality endpoint are
    /// ordinary media that answer byte ranges; a transcode is produced as it is
    /// sent, so it has no length and no position to move to.
    var url: URL? { get }
    var isReadyToPlay: Bool { get }
    /// How far playback has got by this item's own clock, which starts at zero
    /// even when the item is a stream cut from the middle of a track.
    var playedTime: TimeInterval { get }
    /// The item's own length. Not a number for a transcode.
    var loadedDuration: TimeInterval { get }
    func seek(to time: TimeInterval, tolerance: TimeInterval, completion: @escaping (Bool) -> Void)
}

extension PlaybackItemHandle {
    func seek(to time: TimeInterval, tolerance: TimeInterval) {
        seek(to: time, tolerance: tolerance) { _ in }
    }
}

/// What the engine tells the player, in the order it happens.
enum PlaybackEngineEvent {
    /// The playing item's own clock, sampled twice a second.
    case timeObserved(TimeInterval)
    case itemEnded(any PlaybackItemHandle)
    case itemReady(any PlaybackItemHandle)
    case itemFailed(any PlaybackItemHandle, Error)
    case bufferEmptied(any PlaybackItemHandle)
    case bufferRecovered(any PlaybackItemHandle)
    case activityChanged(PlaybackActivity)
}

protocol PlaybackEngine: AnyObject {
    var onEvent: ((PlaybackEngineEvent) -> Void)? { get set }
    var currentItem: (any PlaybackItemHandle)? { get }
    var activity: PlaybackActivity { get }
    var rate: Float { get set }

    /// Builds an item without loading it. Streaming items are given a buffering
    /// policy; local files are left alone.
    func makeItem(url: URL, bufferedForStreaming: Bool) -> any PlaybackItemHandle
    /// Takes a fresh queue, discarding whatever was loaded before.
    func load(_ items: [any PlaybackItemHandle])
    /// Queues an item behind everything already loaded.
    func append(_ item: any PlaybackItemHandle)
    func remove(_ item: any PlaybackItemHandle)
    /// Exchanges what is playing, leaving the items queued behind it in place.
    func replaceCurrentItem(with item: any PlaybackItemHandle)
    func play()
    func pause()
    /// Stops, releases the queue, and stops reporting events.
    func shutDown()
}

// MARK: - AVFoundation

final class AVPlaybackEngine: PlaybackEngine {
    var onEvent: ((PlaybackEngineEvent) -> Void)?

    private var player: AVQueuePlayer?
    private var timeObserver: Any?
    /// Item observations, dropped wholesale when the queue is replaced.
    private var itemObservations = Set<AnyCancellable>()
    /// Observations of the player itself, which is rebuilt with every queue.
    private var queueObservations = Set<AnyCancellable>()
    /// Observations that outlive any one queue.
    private var lifetimeObservations = Set<AnyCancellable>()
    /// Every handle this engine has made, so an AVFoundation callback about an
    /// item can be reported as the handle the player already holds.
    private var handles: [AVPlaybackItem] = []

    /// How often the clock is sampled. Fine enough for a progress bar, coarse
    /// enough that the position rules are not re-evaluated needlessly.
    private let observationInterval = CMTime(seconds: 0.5, preferredTimescale: 1000)

    init() {
        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
            // AVFoundation posts this off the main thread, and what the player
            // does with it publishes to the UI.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self,
                      let item = notification.object as? AVPlayerItem,
                      let handle = self.handle(for: item) else { return }
                self.onEvent?(.itemEnded(handle))
            }
            .store(in: &lifetimeObservations)
    }

    var currentItem: (any PlaybackItemHandle)? {
        guard let item = player?.currentItem else { return nil }
        return handle(for: item)
    }

    var activity: PlaybackActivity {
        guard let player else { return .paused }
        return PlaybackActivity(player.timeControlStatus)
    }

    var rate: Float {
        get { player?.rate ?? 0 }
        set { player?.rate = newValue }
    }

    func makeItem(url: URL, bufferedForStreaming: Bool) -> any PlaybackItemHandle {
        // Without precise timing, AVFoundation reads a FLAC's seek table and,
        // when there isn't one, estimates — reporting the position asked for
        // while playing from wherever the estimate landed. About one FLAC in ten
        // here has no seek table, and VLC plays those correctly, so the file is
        // not at fault. Precise timing makes it parse instead of guess.
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        let item = AVPlayerItem(asset: asset)

        if bufferedForStreaming {
            item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
            // Kept short: a long buffer made preloaded items start mid-stream.
            item.preferredForwardBufferDuration = 15
        }

        let handle = AVPlaybackItem(item: item)
        handles.append(handle)
        observe(handle)
        return handle
    }

    func load(_ items: [any PlaybackItemHandle]) {
        releasePlayer()

        let avItems = items.compactMap { ($0 as? AVPlaybackItem)?.item }
        let player = AVQueuePlayer(items: avItems)
        player.automaticallyWaitsToMinimizeStalling = true
        player.volume = 1.0
        self.player = player

        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.onEvent?(.activityChanged(PlaybackActivity(status)))
            }
            .store(in: &queueObservations)

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: observationInterval, queue: .main
        ) { [weak self] time in
            guard time.isValid, time.isNumeric else { return }
            self?.onEvent?(.timeObserved(time.seconds))
        }
    }

    func append(_ item: any PlaybackItemHandle) {
        guard let avItem = (item as? AVPlaybackItem)?.item else { return }
        player?.insert(avItem, after: nil)
    }

    func remove(_ item: any PlaybackItemHandle) {
        guard let avItem = (item as? AVPlaybackItem)?.item else { return }
        player?.remove(avItem)
        handles.removeAll { $0 === item }
    }

    func replaceCurrentItem(with item: any PlaybackItemHandle) {
        guard let avItem = (item as? AVPlaybackItem)?.item else { return }
        player?.replaceCurrentItem(with: avItem)
    }

    func play() {
        player?.play()
    }

    func pause() {
        player?.pause()
    }

    func shutDown() {
        releasePlayer()
        handles.removeAll()
        itemObservations.removeAll()
    }

    private func releasePlayer() {
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        player?.pause()
        player = nil
        queueObservations.removeAll()
    }

    private func handle(for item: AVPlayerItem) -> AVPlaybackItem? {
        handles.first { $0.item === item }
    }

    /// Every item is watched from the moment it is made, so one swapped in to
    /// seek a transcode is looked after exactly like one loaded with the queue.
    private func observe(_ handle: AVPlaybackItem) {
        let item = handle.item

        item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak handle] status in
                guard let self, let handle else { return }
                switch status {
                case .readyToPlay:
                    self.onEvent?(.itemReady(handle))
                case .failed:
                    let error = item.error ?? NSError(
                        domain: "PlaybackEngine",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Unknown playback error"]
                    )
                    self.onEvent?(.itemFailed(handle, error))
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
            .store(in: &itemObservations)

        item.publisher(for: \.isPlaybackBufferEmpty)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak handle] isEmpty in
                guard let self, let handle, isEmpty else { return }
                self.onEvent?(.bufferEmptied(handle))
            }
            .store(in: &itemObservations)

        item.publisher(for: \.isPlaybackLikelyToKeepUp)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak handle] isLikely in
                guard let self, let handle, isLikely else { return }
                self.onEvent?(.bufferRecovered(handle))
            }
            .store(in: &itemObservations)
    }
}

/// An `AVPlayerItem` under the name the player knows it by.
private final class AVPlaybackItem: PlaybackItemHandle {
    let item: AVPlayerItem

    init(item: AVPlayerItem) {
        self.item = item
    }

    var url: URL? {
        (item.asset as? AVURLAsset)?.url
    }

    var isReadyToPlay: Bool {
        item.status == .readyToPlay
    }

    var playedTime: TimeInterval {
        item.currentTime().seconds
    }

    var loadedDuration: TimeInterval {
        item.duration.seconds
    }

    func seek(
        to time: TimeInterval,
        tolerance: TimeInterval,
        completion: @escaping (Bool) -> Void
    ) {
        let target = CMTime(seconds: time, preferredTimescale: 600)
        let slack = tolerance > 0
            ? CMTime(seconds: tolerance, preferredTimescale: 600)
            : CMTime.zero
        item.seek(to: target, toleranceBefore: slack, toleranceAfter: slack, completionHandler: completion)
    }
}

extension PlaybackActivity {
    init(_ status: AVPlayer.TimeControlStatus) {
        switch status {
        case .playing:
            self = .playing
        case .waitingToPlayAtSpecifiedRate:
            self = .waitingToStart
        case .paused:
            self = .paused
        @unknown default:
            self = .paused
        }
    }
}
