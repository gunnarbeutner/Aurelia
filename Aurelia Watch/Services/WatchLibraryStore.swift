import Combine
import Foundation
import GRDB

nonisolated struct WatchLibraryScope: Codable, Hashable, Sendable {
    let serverKey: String
    let userID: String

    init?(baseURL: String, userID: String?) {
        let trimmedUserID = userID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUserID.isEmpty, !trimmedURL.isEmpty else { return nil }

        if var components = URLComponents(string: trimmedURL) {
            components.scheme = components.scheme?.lowercased()
            components.host = components.host?.lowercased()
            while components.path.count > 1 && components.path.hasSuffix("/") {
                components.path.removeLast()
            }
            components.query = nil
            components.fragment = nil
            serverKey = components.string ?? trimmedURL.lowercased()
        } else {
            serverKey = trimmedURL.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        self.userID = trimmedUserID
    }
}

/// Versioned, credential-free payload transferred from the phone and also
/// produced by the Watch's direct Jellyfin fallback.
nonisolated struct WatchLibraryTransferSnapshot: Codable, Sendable {
    static let currentVersion = 2

    enum Mode: String, Codable, Sendable {
        case full
        case delta
    }

    let version: Int
    let scope: WatchLibraryScope
    let generatedAt: Date
    let mode: Mode
    let baseRevision: Int64?
    let revision: Int64
    let removedItemIDs: [String]
    let artists: [WatchArtist]
    let albums: [WatchAlbum]
    let tracks: [WatchTrack]

    init(
        scope: WatchLibraryScope,
        generatedAt: Date = Date(),
        mode: Mode = .full,
        baseRevision: Int64? = nil,
        revision: Int64 = 0,
        removedItemIDs: [String] = [],
        artists: [WatchArtist],
        albums: [WatchAlbum],
        tracks: [WatchTrack]
    ) {
        version = Self.currentVersion
        self.scope = scope
        self.generatedAt = generatedAt
        self.mode = mode
        self.baseRevision = baseRevision
        self.revision = revision
        self.removedItemIDs = removedItemIDs
        self.artists = artists
        self.albums = albums
        self.tracks = tracks
    }
}

actor WatchLibraryRepository {
    static let shared: WatchLibraryRepository = {
        do {
            let directory = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            return try WatchLibraryRepository(
                databaseURL: directory.appendingPathComponent("AureliaWatchLibrary.sqlite")
            )
        } catch {
            fatalError("Unable to open the Watch library database: \(error)")
        }
    }()

    private let database: DatabasePool

    init(databaseURL: URL) throws {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        database = try DatabasePool(path: databaseURL.path, configuration: configuration)
        try Self.makeMigrator().migrate(database)
    }

    func replace(with snapshot: WatchLibraryTransferSnapshot) throws {
        guard snapshot.version == WatchLibraryTransferSnapshot.currentVersion else {
            throw WatchLibraryStoreError.unsupportedSnapshotVersion(snapshot.version)
        }

        try database.write { db in
            let currentRow = try Row.fetchOne(
                db,
                sql: """
                    SELECT syncedAt, catalogRevision FROM watchLibrarySyncState
                    WHERE serverKey = ? AND userID = ?
                    """,
                arguments: [snapshot.scope.serverKey, snapshot.scope.userID]
            )
            let existingDate: Date? = currentRow?["syncedAt"]
            let currentRevision: Int64 = currentRow?["catalogRevision"] ?? 0
            if let existingDate, existingDate > snapshot.generatedAt {
                return
            }

            if snapshot.mode == .delta,
               snapshot.baseRevision != currentRevision {
                throw WatchLibraryStoreError.revisionMismatch
            }

            let scopeArguments: StatementArguments = [
                snapshot.scope.serverKey,
                snapshot.scope.userID
            ]
            if snapshot.mode == .full {
                for table in ["watchTrackArtist", "watchTrack", "watchAlbumArtist", "watchAlbum", "watchArtist"] {
                    try db.execute(
                        sql: "DELETE FROM \(table) WHERE serverKey = ? AND userID = ?",
                        arguments: scopeArguments
                    )
                }
            } else {
                for itemID in snapshot.removedItemIDs {
                    for statement in [
                        "DELETE FROM watchTrackArtist WHERE serverKey = ? AND userID = ? AND (trackID = ? OR artistID = ?)",
                        "DELETE FROM watchAlbumArtist WHERE serverKey = ? AND userID = ? AND (albumID = ? OR artistID = ?)",
                        "DELETE FROM watchTrack WHERE serverKey = ? AND userID = ? AND itemID = ?",
                        "DELETE FROM watchAlbum WHERE serverKey = ? AND userID = ? AND itemID = ?",
                        "DELETE FROM watchArtist WHERE serverKey = ? AND userID = ? AND itemID = ?"
                    ] {
                        let arguments: StatementArguments = statement.contains(" OR ")
                            ? [snapshot.scope.serverKey, snapshot.scope.userID, itemID, itemID]
                            : [snapshot.scope.serverKey, snapshot.scope.userID, itemID]
                        try db.execute(sql: statement, arguments: arguments)
                    }
                }
            }

            for artist in snapshot.artists {
                try db.execute(
                    sql: """
                        INSERT INTO watchArtist (serverKey, userID, itemID, name)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(serverKey, userID, itemID) DO UPDATE SET
                            name = excluded.name
                        """,
                    arguments: [snapshot.scope.serverKey, snapshot.scope.userID, artist.id, artist.name]
                )
            }

            for album in snapshot.albums {
                try db.execute(
                    sql: "DELETE FROM watchAlbumArtist WHERE serverKey = ? AND userID = ? AND albumID = ?",
                    arguments: [snapshot.scope.serverKey, snapshot.scope.userID, album.id]
                )
                try db.execute(
                    sql: """
                        INSERT INTO watchAlbum
                            (serverKey, userID, itemID, name, artist, artistID, productionYear)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(serverKey, userID, itemID) DO UPDATE SET
                            name = excluded.name,
                            artist = excluded.artist,
                            artistID = excluded.artistID,
                            productionYear = excluded.productionYear
                        """,
                    arguments: [
                        snapshot.scope.serverKey,
                        snapshot.scope.userID,
                        album.id,
                        album.name,
                        album.artist,
                        album.artistId,
                        album.year
                    ]
                )
                if let artistID = album.artistId, !artistID.isEmpty {
                    try db.execute(
                        sql: """
                            INSERT OR IGNORE INTO watchAlbumArtist
                                (serverKey, userID, albumID, artistID)
                            VALUES (?, ?, ?, ?)
                            """,
                        arguments: [
                            snapshot.scope.serverKey,
                            snapshot.scope.userID,
                            album.id,
                            artistID
                        ]
                    )
                }
            }

            for track in snapshot.tracks {
                try db.execute(
                    sql: "DELETE FROM watchTrackArtist WHERE serverKey = ? AND userID = ? AND trackID = ?",
                    arguments: [snapshot.scope.serverKey, snapshot.scope.userID, track.id]
                )
                try db.execute(
                    sql: """
                        INSERT INTO watchTrack
                            (serverKey, userID, itemID, name, artist, album, albumID, duration,
                             indexNumber, parentIndexNumber, isFavorite)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(serverKey, userID, itemID) DO UPDATE SET
                            name = excluded.name,
                            artist = excluded.artist,
                            album = excluded.album,
                            albumID = excluded.albumID,
                            duration = excluded.duration,
                            indexNumber = excluded.indexNumber,
                            parentIndexNumber = excluded.parentIndexNumber,
                            isFavorite = excluded.isFavorite
                        """,
                    arguments: [
                        snapshot.scope.serverKey,
                        snapshot.scope.userID,
                        track.id,
                        track.name,
                        track.artist,
                        track.album,
                        track.albumId,
                        track.duration,
                        track.indexNumber,
                        track.parentIndexNumber,
                        track.isFavorite
                    ]
                )
                for (position, artistID) in track.artistIds.enumerated() where !artistID.isEmpty {
                    try db.execute(
                        sql: """
                            INSERT OR IGNORE INTO watchTrackArtist
                                (serverKey, userID, trackID, artistID, position)
                            VALUES (?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            snapshot.scope.serverKey,
                            snapshot.scope.userID,
                            track.id,
                            artistID,
                            position
                        ]
                    )
                }
            }

            try db.execute(
                sql: """
                    INSERT INTO watchLibrarySyncState (
                        serverKey, userID, syncedAt, snapshotVersion, catalogRevision
                    ) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(serverKey, userID) DO UPDATE SET
                        syncedAt = excluded.syncedAt,
                        snapshotVersion = excluded.snapshotVersion,
                        catalogRevision = excluded.catalogRevision
                    """,
                arguments: [
                    snapshot.scope.serverKey,
                    snapshot.scope.userID,
                    snapshot.generatedAt,
                    snapshot.version,
                    snapshot.revision
                ]
            )
        }
    }

    func snapshot(in scope: WatchLibraryScope) throws -> WatchLibraryTransferSnapshot? {
        try database.read { db in
            guard let generatedAt = try Date.fetchOne(
                db,
                sql: """
                    SELECT syncedAt FROM watchLibrarySyncState
                    WHERE serverKey = ? AND userID = ?
                    """,
                arguments: [scope.serverKey, scope.userID]
            ) else {
                return nil
            }

            return WatchLibraryTransferSnapshot(
                scope: scope,
                generatedAt: generatedAt,
                revision: try Int64.fetchOne(
                    db,
                    sql: """
                        SELECT catalogRevision FROM watchLibrarySyncState
                        WHERE serverKey = ? AND userID = ?
                        """,
                    arguments: [scope.serverKey, scope.userID]
                ) ?? 0,
                artists: try Self.artists(db, scope: scope),
                albums: try Self.albums(db, scope: scope),
                tracks: try Self.tracks(db, scope: scope)
            )
        }
    }

    func albums(for artist: WatchArtist, in scope: WatchLibraryScope) throws -> [WatchAlbum] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT album.*
                    FROM watchAlbum AS album
                    LEFT JOIN watchAlbumArtist AS relationship
                      ON relationship.serverKey = album.serverKey
                     AND relationship.userID = album.userID
                     AND relationship.albumID = album.itemID
                    WHERE album.serverKey = ? AND album.userID = ?
                      AND (relationship.artistID = ? OR (album.artistID IS NULL AND album.artist = ?))
                    ORDER BY album.productionYear DESC, album.name COLLATE NOCASE
                    """,
                arguments: [scope.serverKey, scope.userID, artist.id, artist.name]
            )
            return rows.map(Self.album(from:))
        }
    }

    func tracks(for artist: WatchArtist, in scope: WatchLibraryScope) throws -> [WatchTrack] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT track.*
                    FROM watchTrack AS track
                    LEFT JOIN watchTrackArtist AS relationship
                      ON relationship.serverKey = track.serverKey
                     AND relationship.userID = track.userID
                     AND relationship.trackID = track.itemID
                    WHERE track.serverKey = ? AND track.userID = ?
                      AND (relationship.artistID = ? OR (relationship.artistID IS NULL AND track.artist = ?))
                    ORDER BY track.album COLLATE NOCASE,
                             COALESCE(track.parentIndexNumber, 0),
                             COALESCE(track.indexNumber, 0),
                             track.name COLLATE NOCASE
                    """,
                arguments: [scope.serverKey, scope.userID, artist.id, artist.name]
            )
            return try rows.map { try Self.track(from: $0, db: db, scope: scope) }
        }
    }

    func tracks(inAlbum albumID: String, in scope: WatchLibraryScope) throws -> [WatchTrack] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM watchTrack
                    WHERE serverKey = ? AND userID = ? AND albumID = ?
                    ORDER BY COALESCE(parentIndexNumber, 0),
                             COALESCE(indexNumber, 0),
                             name COLLATE NOCASE
                    """,
                arguments: [scope.serverKey, scope.userID, albumID]
            )
            return try rows.map { try Self.track(from: $0, db: db, scope: scope) }
        }
    }

    private static func artists(_ db: Database, scope: WatchLibraryScope) throws -> [WatchArtist] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM watchArtist
                WHERE serverKey = ? AND userID = ?
                ORDER BY name COLLATE NOCASE
                """,
            arguments: [scope.serverKey, scope.userID]
        ).map { WatchArtist(id: $0["itemID"], name: $0["name"]) }
    }

    private static func albums(_ db: Database, scope: WatchLibraryScope) throws -> [WatchAlbum] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM watchAlbum
                WHERE serverKey = ? AND userID = ?
                ORDER BY name COLLATE NOCASE
                """,
            arguments: [scope.serverKey, scope.userID]
        ).map(album(from:))
    }

    private static func tracks(_ db: Database, scope: WatchLibraryScope) throws -> [WatchTrack] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM watchTrack
                WHERE serverKey = ? AND userID = ?
                ORDER BY album COLLATE NOCASE,
                         COALESCE(parentIndexNumber, 0),
                         COALESCE(indexNumber, 0),
                         name COLLATE NOCASE
                """,
            arguments: [scope.serverKey, scope.userID]
        )
        return try rows.map { try track(from: $0, db: db, scope: scope) }
    }

    private static func album(from row: Row) -> WatchAlbum {
        WatchAlbum(
            id: row["itemID"],
            name: row["name"],
            artist: row["artist"],
            artistId: row["artistID"],
            year: row["productionYear"]
        )
    }

    private static func track(
        from row: Row,
        db: Database,
        scope: WatchLibraryScope
    ) throws -> WatchTrack {
        let trackID: String = row["itemID"]
        let artistIDs = try String.fetchAll(
            db,
            sql: """
                SELECT artistID FROM watchTrackArtist
                WHERE serverKey = ? AND userID = ? AND trackID = ?
                ORDER BY position
                """,
            arguments: [scope.serverKey, scope.userID, trackID]
        )
        return WatchTrack(
            id: trackID,
            name: row["name"],
            artist: row["artist"],
            artistIds: artistIDs,
            album: row["album"],
            albumId: row["albumID"],
            duration: row["duration"],
            indexNumber: row["indexNumber"],
            parentIndexNumber: row["parentIndexNumber"],
            isFavorite: row["isFavorite"]
        )
    }

    private static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createWatchLibrary") { db in
            try db.create(table: "watchArtist") { table in
                table.column("serverKey", .text).notNull()
                table.column("userID", .text).notNull()
                table.column("itemID", .text).notNull()
                table.column("name", .text).notNull()
                table.primaryKey(["serverKey", "userID", "itemID"])
            }
            try db.create(table: "watchAlbum") { table in
                table.column("serverKey", .text).notNull()
                table.column("userID", .text).notNull()
                table.column("itemID", .text).notNull()
                table.column("name", .text).notNull()
                table.column("artist", .text).notNull()
                table.column("artistID", .text)
                table.column("productionYear", .integer)
                table.primaryKey(["serverKey", "userID", "itemID"])
            }
            try db.create(table: "watchAlbumArtist") { table in
                table.column("serverKey", .text).notNull()
                table.column("userID", .text).notNull()
                table.column("albumID", .text).notNull()
                table.column("artistID", .text).notNull()
                table.primaryKey(["serverKey", "userID", "albumID", "artistID"])
            }
            try db.create(index: "watchAlbumArtistByArtist", on: "watchAlbumArtist", columns: ["serverKey", "userID", "artistID"])
            try db.create(table: "watchTrack") { table in
                table.column("serverKey", .text).notNull()
                table.column("userID", .text).notNull()
                table.column("itemID", .text).notNull()
                table.column("name", .text).notNull()
                table.column("artist", .text).notNull()
                table.column("album", .text).notNull()
                table.column("albumID", .text).notNull()
                table.column("duration", .double).notNull()
                table.column("indexNumber", .integer)
                table.column("parentIndexNumber", .integer)
                table.column("isFavorite", .boolean).notNull()
                table.primaryKey(["serverKey", "userID", "itemID"])
            }
            try db.create(index: "watchTrackByAlbum", on: "watchTrack", columns: ["serverKey", "userID", "albumID"])
            try db.create(table: "watchTrackArtist") { table in
                table.column("serverKey", .text).notNull()
                table.column("userID", .text).notNull()
                table.column("trackID", .text).notNull()
                table.column("artistID", .text).notNull()
                table.column("position", .integer).notNull()
                table.primaryKey(["serverKey", "userID", "trackID", "artistID"])
            }
            try db.create(index: "watchTrackArtistByArtist", on: "watchTrackArtist", columns: ["serverKey", "userID", "artistID"])
            try db.create(table: "watchLibrarySyncState") { table in
                table.column("serverKey", .text).notNull()
                table.column("userID", .text).notNull()
                table.column("syncedAt", .datetime).notNull()
                table.column("snapshotVersion", .integer).notNull()
                table.column("catalogRevision", .integer).notNull().defaults(to: 0)
                table.primaryKey(["serverKey", "userID"])
            }
        }
        migrator.registerMigration("addWatchCatalogRevision") { db in
            // Fresh databases already include the column above. Existing
            // version-one caches need it added exactly once.
            let columns = try db.columns(in: "watchLibrarySyncState")
            if !columns.contains(where: { $0.name == "catalogRevision" }) {
                try db.alter(table: "watchLibrarySyncState") { table in
                    table.add(column: "catalogRevision", .integer).notNull().defaults(to: 0)
                }
            }
        }
        return migrator
    }
}

enum WatchLibraryStoreError: LocalizedError {
    case unsupportedSnapshotVersion(Int)
    case revisionMismatch

    var errorDescription: String? {
        switch self {
        case .unsupportedSnapshotVersion(let version):
            return "Unsupported library snapshot version \(version)."
        case .revisionMismatch:
            return "The Watch library needs a complete snapshot."
        }
    }
}

@MainActor
final class WatchLibraryStore: ObservableObject {
    static let shared = WatchLibraryStore(
        service: .shared,
        repository: .shared
    )

    @Published private(set) var artists: [WatchArtist] = []
    @Published private(set) var albums: [WatchAlbum] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasCachedLibrary = false

    private let service: WatchJellyfinService
    private let repository: WatchLibraryRepository
    private var activeScope: WatchLibraryScope?
    private var fallbackTask: Task<Void, Never>?

    init(service: WatchJellyfinService, repository: WatchLibraryRepository) {
        self.service = service
        self.repository = repository
    }

    func activate() async {
        guard let scope = service.libraryScope else {
            clear()
            return
        }
        activeScope = scope
        await reload(in: scope)
        WatchConnectivityManager.shared.requestLibrarySnapshot()

        guard !hasCachedLibrary else { return }
        fallbackTask?.cancel()
        fallbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, !Task.isCancelled, !self.hasCachedLibrary else { return }
            await self.refreshDirectlyFromServer()
        }
    }

    func applyTransferredSnapshot(_ data: Data) async {
        do {
            let snapshot = try JSONDecoder().decode(WatchLibraryTransferSnapshot.self, from: data)
            guard let currentScope = service.libraryScope, snapshot.scope == currentScope else {
                return
            }
            try await repository.replace(with: snapshot)
            fallbackTask?.cancel()
            await reload(in: currentScope)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            if case WatchLibraryStoreError.revisionMismatch = error {
                WatchConnectivityManager.shared.requestLibrarySnapshot()
            }
        }
    }

    func refreshDirectlyFromServer() async {
        guard let scope = service.libraryScope else { return }
        isLoading = !hasCachedLibrary
        defer { isLoading = false }
        do {
            let snapshot = try await service.fetchCompleteLibrarySnapshot()
            guard snapshot.scope == scope else { return }
            try await repository.replace(with: snapshot)
            await reload(in: scope)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func albums(for artist: WatchArtist) async throws -> [WatchAlbum] {
        guard let scope = activeScope ?? service.libraryScope else { return [] }
        return try await repository.albums(for: artist, in: scope)
    }

    func tracks(for artist: WatchArtist) async throws -> [WatchTrack] {
        guard let scope = activeScope ?? service.libraryScope else { return [] }
        return try await repository.tracks(for: artist, in: scope)
    }

    func tracks(inAlbum albumID: String) async throws -> [WatchTrack] {
        guard let scope = activeScope ?? service.libraryScope else { return [] }
        return try await repository.tracks(inAlbum: albumID, in: scope)
    }

    func deactivate() {
        fallbackTask?.cancel()
        clear()
    }

    private func reload(in scope: WatchLibraryScope) async {
        do {
            guard let snapshot = try await repository.snapshot(in: scope) else {
                artists = []
                albums = []
                hasCachedLibrary = false
                return
            }
            artists = snapshot.artists
            albums = snapshot.albums
            hasCachedLibrary = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clear() {
        activeScope = nil
        artists = []
        albums = []
        errorMessage = nil
        hasCachedLibrary = false
        isLoading = false
    }
}
