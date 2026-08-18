//
//  NowPlayingPublisher.swift
//  Aurelia
//
//  Mirrors the player into the shared app group for the widget extension
//

import Combine
import Foundation
import UIKit
import WidgetKit
import os

/// Watches `PlayerManager` from the outside and republishes what it sees into
/// the app group. Observing rather than being called from the player keeps the
/// widget's needs out of the playback path.
final class NowPlayingPublisher {
    static let shared = NowPlayingPublisher()

    private let logger = Logger(subsystem: "de.beutner.Aurelia", category: "NowPlayingPublisher")
    private var cancellables = Set<AnyCancellable>()
    private var artworkTask: Task<Void, Never>?
    private var published: NowPlayingSnapshot?
    private var hasPublishScheduled = false

    /// How far the player's clock may drift from what a widget would project
    /// before the snapshot is rewritten. Ordinary playback never crosses it;
    /// a seek always does.
    private let driftTolerance: TimeInterval = 1.5

    private init() {}

    func start() {
        registerTransportBridge()
        observePlayer()
        publish()
    }

    // MARK: - Transport

    /// The widget's buttons name intents that carry no player of their own.
    /// This is the app half they reach once the system routes them here.
    private func registerTransportBridge() {
        PlaybackCommandBridge.handler = { command in
            switch command {
            case .resume: return AureliaActions.resume().message
            case .pause: return AureliaActions.pause().message
            case .next: return AureliaActions.skip(forward: true).message
            case .previous: return AureliaActions.skip(forward: false).message
            }
        }
    }

    // MARK: - Observation

    private func observePlayer() {
        let player = PlayerManager.shared

        player.$currentTrack
            .map(\.?.id)
            .removeDuplicates()
            .sink { [weak self] _ in self?.schedulePublish() }
            .store(in: &cancellables)

        player.$isPlaying
            .removeDuplicates()
            .sink { [weak self] _ in self?.schedulePublish() }
            .store(in: &cancellables)

        player.$duration
            .removeDuplicates()
            .sink { [weak self] _ in self?.schedulePublish() }
            .store(in: &cancellables)

        // A playing snapshot carries its own clock forward, so the twice-a-second
        // tick is only worth acting on when it disagrees with that projection.
        player.playbackProgress.$currentTime
            .sink { [weak self] time in
                guard let self, let published else { return }
                let projected = published.elapsed(at: Date())
                if abs(projected - time) > driftTolerance {
                    schedulePublish()
                }
            }
            .store(in: &cancellables)
    }

    /// `@Published` fires from `willSet`, so inside those sinks the player
    /// still reports the state it is leaving. Reading it on the next turn of
    /// the run loop reads what the change settled on; without the hop a pause
    /// is mirrored as still playing. It also collapses the several signals one
    /// user action sends into a single write.
    private func schedulePublish() {
        guard !hasPublishScheduled else { return }
        hasPublishScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            hasPublishScheduled = false
            publish()
        }
    }

    // MARK: - Publishing

    private func publish() {
        let player = PlayerManager.shared

        guard let track = player.currentTrack else {
            published = nil
            artworkTask?.cancel()
            SharedContainer.clearSnapshot()
            SharedContainer.pruneArtwork(keeping: nil)
            WidgetCenter.shared.reloadAllTimelines()
            return
        }

        // Artwork survives a track staying put, so only the file name is
        // carried over and a new export is started when the track changes.
        let carriedArtwork = published?.trackID == track.id ? published?.artworkFileName : nil

        let snapshot = NowPlayingSnapshot(
            trackID: track.id,
            title: track.name,
            artistName: track.artistName,
            albumName: track.albumName,
            albumID: track.albumId,
            isPlaying: player.isPlaying,
            duration: player.duration > 0 ? player.duration : track.duration,
            elapsed: player.currentTime,
            writtenAt: Date(),
            artworkFileName: carriedArtwork
        )

        if carriedArtwork == nil {
            exportArtwork(for: track)
        }

        write(snapshot)
    }

    private func write(_ snapshot: NowPlayingSnapshot) {
        if let published, published.matchesDisplay(of: snapshot, tolerance: driftTolerance) {
            return
        }
        published = snapshot
        SharedContainer.save(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func exportArtwork(for track: Track) {
        artworkTask?.cancel()

        guard let artworkURL = track.artworkURL.flatMap(URL.init(string:)) else {
            SharedContainer.pruneArtwork(keeping: nil)
            return
        }

        artworkTask = Task { [weak self] in
            guard let image = try? await ImageCache.shared.loadImage(from: artworkURL) else { return }
            guard !Task.isCancelled else { return }
            guard let self, published?.trackID == track.id else { return }
            guard let fileName = SharedContainer.writeArtwork(image, forTrackID: track.id) else { return }

            guard var snapshot = published, snapshot.trackID == track.id else { return }
            snapshot.artworkFileName = fileName
            write(snapshot)
        }
    }

}
