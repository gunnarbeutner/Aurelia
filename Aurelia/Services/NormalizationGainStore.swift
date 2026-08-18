//
//  NormalizationGainStore.swift
//  Aurelia
//
//  The measured gains, kept where playback can read one without waiting.
//
//  Jellyfin sends the numbers on the track item itself, and the catalog Aurelia
//  syncs does not carry them, so they are fetched by identifier for the songs
//  about to play and kept in SQLite from then on. That store is also what a
//  download plays by: a track heard once online keeps its gain when there is no
//  server in reach.
//

import Foundation
import os.log

final class NormalizationGainStore {
    static let shared = NormalizationGainStore()

    private let logger = Logger(subsystem: "de.beutner.Aurelia", category: "VolumeNormalization")
    private let jellyfinService: JellyfinService
    private let repository: LibraryRepository

    /// Every answer so far, including the empty ones.
    private var known: [String: NormalizationGain] = [:]
    /// Identifiers a request is already out for, so the same song queued twice
    /// is asked about once.
    private var loading: Set<String> = []

    /// Identifiers per request. A whole queue's worth in one or two round
    /// trips, while keeping the URL to a length any server will take.
    private static let batchSize = 100

    init(jellyfinService: JellyfinService = .shared, repository: LibraryRepository = .shared) {
        self.jellyfinService = jellyfinService
        self.repository = repository
    }

    /// What is already in hand for a track, if anything.
    func gain(for trackID: String) -> NormalizationGain? {
        known[trackID]
    }

    /// Reads whatever is not already in hand: the local catalog first, the
    /// server for the rest.
    ///
    /// Nothing is stored when the server cannot be reached, so a queue built
    /// offline is asked about again once it can be.
    func load(_ trackIDs: [String]) async {
        let wanted = trackIDs.filter { known[$0] == nil && !loading.contains($0) }
        guard !wanted.isEmpty, let scope = jellyfinService.libraryScope else { return }

        loading.formUnion(wanted)
        defer { loading.subtract(wanted) }

        let stored = await repository.normalizationGains(for: wanted, in: scope)
        known.merge(stored) { current, _ in current }

        let missing = wanted.filter { stored[$0] == nil }
        guard !missing.isEmpty else { return }

        var fetched: [String: NormalizationGain] = [:]
        for batch in stride(from: 0, to: missing.count, by: Self.batchSize) {
            let ids = Array(missing[batch..<min(batch + Self.batchSize, missing.count)])
            fetched.merge(await jellyfinService.fetchNormalizationGains(for: ids)) { current, _ in current }
        }
        guard !fetched.isEmpty else { return }

        known.merge(fetched) { _, latest in latest }
        await repository.saveNormalizationGains(fetched, in: scope)
        logger.info("🔊 Read normalization gains for \(fetched.count) tracks")
    }
}
