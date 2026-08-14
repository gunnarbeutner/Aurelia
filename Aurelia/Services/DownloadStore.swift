//
//  DownloadStore.swift
//  Aurelia
//
//  Persistence for offline downloads.
//
//  Downloads used to live in a single JSON blob in UserDefaults that was
//  re-encoded in full every time one track finished. That is quadratic over a
//  batch and puts megabytes somewhere UserDefaults was never meant to hold, so
//  the records moved to their own SQLite file. It is deliberately *not* part of
//  the library database: every row there is scoped to one Jellyfin account,
//  while a downloaded file belongs to the device.
//

import Foundation
import GRDB
import os.log

/// Who asked for a downloaded file to exist.
///
/// A file can have more than one owner — liking an album you had already
/// downloaded by hand does not change the file, only who is holding onto it —
/// and it survives until the last owner lets go.
nonisolated enum DownloadOrigin: String, Codable, Sendable, CaseIterable {
    /// Requested directly by the user, from a track or album menu.
    case manual
    /// Requested by the "Keep Favorites Offline" rule.
    case favoritesRule
}

/// A download that has been asked for but has not produced a file yet.
///
/// Persisted rather than held in memory because a background session outlives
/// the process: a task that finishes while the app is dead calls back into a
/// freshly constructed `DownloadManager`, which has no other way to learn which
/// track the bytes belong to.
nonisolated struct PendingDownload: Sendable, Equatable {
    let track: Track
    /// Same meaning as on a finished download: everyone who wants this file.
    var owners: Set<DownloadOrigin>
    var attempts: Int

    init(track: Track, owners: Set<DownloadOrigin>, attempts: Int = 0) {
        self.track = track
        self.owners = owners
        self.attempts = attempts
    }
}

/// SQLite-backed record of what is on disk and what is still in flight.
///
/// Writes are single-row, so finishing one track in a 400-track batch costs one
/// statement instead of re-encoding the whole catalogue.
final class DownloadStore: Sendable {
    static let shared: DownloadStore = {
        do {
            return try DownloadStore(databaseURL: defaultDatabaseURL())
        } catch {
            fatalError("Unable to open the Aurelia downloads database: \(error)")
        }
    }()

    private let database: DatabaseQueue
    private let logger = Logger(subsystem: "de.beutner.Aurelia", category: "DownloadStore")

    /// Set once the UserDefaults blob has been folded into SQLite.
    private static let migrationFlagKey = "downloadStoreMigratedFromDefaults"
    private static let legacyDownloadsKey = "downloadedTracks"

    init(databaseURL: URL, defaults: UserDefaults = .standard) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        database = try DatabaseQueue(path: databaseURL.path)
        try Self.makeMigrator().migrate(database)

        // The audio files themselves are re-downloadable and already excluded,
        // so the index that describes them should not be backed up either.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = databaseURL
        try? mutableURL.setResourceValues(values)

        importLegacyDownloadsIfNeeded(from: defaults)
    }

    // MARK: - Downloaded tracks

    func loadDownloads() -> [DownloadedTrack] {
        do {
            return try database.read { db in
                try Row.fetchAll(db, sql: "SELECT * FROM downloadedTrack ORDER BY downloadDate")
                    .map(DownloadedTrack.init(row:))
            }
        } catch {
            logger.error("Failed to load downloads: \(error.localizedDescription)")
            return []
        }
    }

    func upsert(_ track: DownloadedTrack) {
        write { db in
            try Self.insert(track, into: db)
        }
    }

    func remove(trackID: String) {
        write { db in
            try db.execute(sql: "DELETE FROM downloadedTrack WHERE trackId = ?", arguments: [trackID])
        }
    }

    func removeAllDownloads() {
        write { db in
            try db.execute(sql: "DELETE FROM downloadedTrack")
        }
    }

    // MARK: - Pending downloads

    func loadPending() -> [PendingDownload] {
        do {
            return try database.read { db in
                try Row.fetchAll(db, sql: "SELECT * FROM pendingDownload")
                    .compactMap { row -> PendingDownload? in
                        let payload: Data = row["payload"]
                        guard let track = try? JSONDecoder().decode(Track.self, from: payload) else {
                            return nil
                        }
                        return PendingDownload(
                            track: track,
                            owners: DownloadedTrack.decode(owners: row["owners"]),
                            attempts: row["attempts"]
                        )
                    }
            }
        } catch {
            logger.error("Failed to load pending downloads: \(error.localizedDescription)")
            return []
        }
    }

    func upsertPending(_ pending: PendingDownload) {
        guard let payload = try? JSONEncoder().encode(pending.track) else {
            logger.error("Failed to encode pending download: \(pending.track.name)")
            return
        }
        write { db in
            try db.execute(
                sql: """
                    INSERT INTO pendingDownload (trackId, owners, attempts, payload)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(trackId) DO UPDATE SET
                        owners = excluded.owners,
                        attempts = excluded.attempts,
                        payload = excluded.payload
                    """,
                arguments: [
                    pending.track.id,
                    DownloadedTrack.encode(owners: pending.owners),
                    pending.attempts,
                    payload
                ]
            )
        }
    }

    func removePending(trackID: String) {
        write { db in
            try db.execute(sql: "DELETE FROM pendingDownload WHERE trackId = ?", arguments: [trackID])
        }
    }

    func removeAllPending() {
        write { db in
            try db.execute(sql: "DELETE FROM pendingDownload")
        }
    }

    // MARK: - Migration

    /// Folds the pre-SQLite UserDefaults blob into the database exactly once.
    ///
    /// Legacy records carry no owner, and `DownloadedTrack` decodes that as
    /// `manual` — anything already on the device was put there by hand, and
    /// treating it as rule-owned would let the first unlike delete it.
    private func importLegacyDownloadsIfNeeded(from defaults: UserDefaults) {
        guard !defaults.bool(forKey: Self.migrationFlagKey) else { return }

        defer {
            defaults.set(true, forKey: Self.migrationFlagKey)
            defaults.removeObject(forKey: Self.legacyDownloadsKey)
        }

        guard let data = defaults.data(forKey: Self.legacyDownloadsKey),
              let legacy = try? JSONDecoder().decode([DownloadedTrack].self, from: data),
              !legacy.isEmpty else {
            return
        }

        write { db in
            for track in legacy {
                try Self.insert(track, into: db)
            }
        }

        logger.info("Migrated \(legacy.count) downloads out of UserDefaults")
    }

    // MARK: - Plumbing

    private func write(_ updates: @escaping (Database) throws -> Void) {
        do {
            try database.write(updates)
        } catch {
            logger.error("Download store write failed: \(error.localizedDescription)")
        }
    }

    private static func insert(_ track: DownloadedTrack, into db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO downloadedTrack (
                    trackId, fileName, fileSize, downloadDate, trackName, artistName,
                    albumName, duration, albumId, trackNumber, discNumber, artistId,
                    productionYear, artworkURL, owners
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(trackId) DO UPDATE SET
                    fileName = excluded.fileName,
                    fileSize = excluded.fileSize,
                    downloadDate = excluded.downloadDate,
                    trackName = excluded.trackName,
                    artistName = excluded.artistName,
                    albumName = excluded.albumName,
                    duration = excluded.duration,
                    albumId = excluded.albumId,
                    trackNumber = excluded.trackNumber,
                    discNumber = excluded.discNumber,
                    artistId = excluded.artistId,
                    productionYear = excluded.productionYear,
                    artworkURL = excluded.artworkURL,
                    owners = excluded.owners
                """,
            arguments: [
                track.trackId,
                track.fileName,
                track.fileSize,
                track.downloadDate,
                track.trackName,
                track.artistName,
                track.albumName,
                track.duration,
                track.albumId,
                track.trackNumber,
                track.discNumber,
                track.artistId,
                track.productionYear,
                track.artworkURL,
                DownloadedTrack.encode(owners: track.owners)
            ]
        )
    }

    private static func defaultDatabaseURL() throws -> URL {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return applicationSupport
            .appendingPathComponent("Aurelia", isDirectory: true)
            .appendingPathComponent("Downloads.sqlite", isDirectory: false)
    }

    private static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createDownloadIndex") { db in
            try db.create(table: "downloadedTrack") { table in
                table.column("trackId", .text).primaryKey()
                table.column("fileName", .text).notNull()
                table.column("fileSize", .integer).notNull()
                table.column("downloadDate", .datetime).notNull()
                table.column("trackName", .text).notNull()
                table.column("artistName", .text).notNull()
                table.column("albumName", .text).notNull()
                table.column("duration", .double)
                table.column("albumId", .text).notNull()
                table.column("trackNumber", .integer)
                table.column("discNumber", .integer)
                table.column("artistId", .text)
                table.column("productionYear", .integer)
                table.column("artworkURL", .text)
                table.column("owners", .text).notNull()
            }
            try db.create(index: "downloadedTrackByAlbum", on: "downloadedTrack", columns: ["albumId"])

            try db.create(table: "pendingDownload") { table in
                table.column("trackId", .text).primaryKey()
                table.column("owners", .text).notNull()
                table.column("attempts", .integer).notNull()
                table.column("payload", .blob).notNull()
            }
        }
        return migrator
    }
}

// MARK: - Row mapping

extension DownloadedTrack {
    init(row: Row) {
        self.init(
            trackId: row["trackId"],
            fileName: row["fileName"],
            fileSize: row["fileSize"],
            downloadDate: row["downloadDate"],
            trackName: row["trackName"],
            artistName: row["artistName"],
            albumName: row["albumName"],
            duration: row["duration"],
            albumId: row["albumId"],
            trackNumber: row["trackNumber"],
            discNumber: row["discNumber"],
            artistId: row["artistId"],
            productionYear: row["productionYear"],
            artworkURL: row["artworkURL"],
            owners: DownloadedTrack.decode(owners: row["owners"])
        )
    }

    /// Owners live in one column rather than a join table. There are two of
    /// them and there is never a query that filters on one.
    static func encode(owners: Set<DownloadOrigin>) -> String {
        owners.map(\.rawValue).sorted().joined(separator: ",")
    }

    static func decode(owners: String) -> Set<DownloadOrigin> {
        let parsed = owners
            .split(separator: ",")
            .compactMap { DownloadOrigin(rawValue: String($0)) }
        // A row with no recognisable owner would be deleted on the next
        // reconcile, which is not a thing a parsing slip should be able to do.
        return parsed.isEmpty ? [.manual] : Set(parsed)
    }
}
