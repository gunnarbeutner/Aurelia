import Foundation
import GRDB
import os.log

/// Identifies one Jellyfin library. Every persisted row is scoped so switching
/// servers or users can never expose metadata from another account.
nonisolated struct LibraryScope: Hashable, Sendable {
    let serverKey: String
    let userID: String

    init?(baseURL: String, userID: String?) {
        let trimmedUserID = userID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedUserID.isEmpty else { return nil }

        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return nil }

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

nonisolated struct LibrarySnapshot: Sendable {
    let albums: [Album]
    let artists: [Artist]
    let playlists: [Playlist]
    let lastSyncedAt: Date?

    var hasCachedLibrary: Bool { lastSyncedAt != nil }
}

nonisolated struct RecentTrackEntry: Sendable {
    let track: Track
    let playedAt: Date
    let playCount: Int?
    let playbackPositionTicks: Int64?

    init(
        track: Track,
        playedAt: Date,
        playCount: Int? = nil,
        playbackPositionTicks: Int64? = nil
    ) {
        self.track = track
        self.playedAt = playedAt
        self.playCount = playCount
        self.playbackPositionTicks = playbackPositionTicks
    }
}

func recentTrackEntries(
    from items: [BaseItemDto],
    baseURL: String,
    fetchedAt: Date = Date()
) -> [RecentTrackEntry] {
    items.enumerated().compactMap { index, item in
        guard item.Type == .Audio else { return nil }
        return RecentTrackEntry(
            track: Track(from: item, baseURL: baseURL),
            // Older Jellyfin servers may omit LastPlayedDate even when sorting
            // by it. Preserve the server order with stable synthetic spacing.
            playedAt: item.UserData?.lastPlayedDate
                ?? fetchedAt.addingTimeInterval(-Double(index)),
            playCount: item.UserData?.PlayCount,
            playbackPositionTicks: item.UserData?.PlaybackPositionTicks
        )
    }
}

nonisolated protocol RecentTrackCaching: Sendable {
    func cachedRecentTracks(in scope: LibraryScope, limit: Int) async -> [Track]
    func replaceRecentlyPlayed(_ entries: [RecentTrackEntry], in scope: LibraryScope) async
}

/// SQLite-backed source of truth for the local Jellyfin metadata cache.
///
/// A single actor owns the pool-facing repository API. GRDB still uses a
/// DatabasePool internally, so observations and future background readers can
/// be added without changing the schema or the view-facing interface.
actor LibraryRepository: RecentTrackCaching {
    static let shared: LibraryRepository = {
        do {
            return try LibraryRepository(databaseURL: defaultDatabaseURL())
        } catch {
            fatalError("Unable to open the JellyAmp library database: \(error)")
        }
    }()

    private let database: DatabasePool
    private let logger = Logger(subsystem: "com.jellyamp.app", category: "LibraryRepository")

    init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        database = try DatabasePool(path: databaseURL.path, configuration: configuration)
        try Self.makeMigrator().migrate(database)

        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = databaseURL
        try? mutableURL.setResourceValues(values)
    }

    // MARK: - Library snapshots

    func librarySnapshot(in scope: LibraryScope) throws -> LibrarySnapshot {
        try database.read { db in
            let favorites = try Self.favoriteItemIDs(db, scope: scope)
            let albums = try Self.items(db, scope: scope, type: .album)
                .map { $0.album(isFavorite: favorites.contains($0.itemID)) }
            let artists = try Self.items(db, scope: scope, type: .artist)
                .map { $0.artist(isFavorite: favorites.contains($0.itemID)) }
            let playlists = try Self.items(db, scope: scope, type: .playlist)
                .map { $0.playlist(isFavorite: favorites.contains($0.itemID)) }
            let syncedAt = try Date.fetchOne(
                db,
                sql: """
                    SELECT librarySyncedAt
                    FROM librarySyncState
                    WHERE serverKey = ? AND userID = ?
                    """,
                arguments: [scope.serverKey, scope.userID]
            )
            return LibrarySnapshot(
                albums: albums,
                artists: artists,
                playlists: playlists,
                lastSyncedAt: syncedAt
            )
        }
    }

    func replaceLibrary(
        albums: [Album],
        artists: [Artist],
        playlists: [Playlist],
        in scope: LibraryScope,
        syncedAt: Date = Date()
    ) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    DELETE FROM libraryItem
                    WHERE serverKey = ? AND userID = ?
                      AND itemType IN (?, ?, ?)
                    """,
                arguments: [
                    scope.serverKey,
                    scope.userID,
                    LibraryItemType.album.rawValue,
                    LibraryItemType.artist.rawValue,
                    LibraryItemType.playlist.rawValue
                ]
            )
            try Self.save(albums: albums, db: db, scope: scope)
            try Self.save(artists: artists, db: db, scope: scope)
            try Self.save(playlists: playlists, db: db, scope: scope)
            try db.execute(
                sql: """
                    INSERT INTO librarySyncState (serverKey, userID, librarySyncedAt)
                    VALUES (?, ?, ?)
                    ON CONFLICT(serverKey, userID) DO UPDATE SET
                        librarySyncedAt = excluded.librarySyncedAt
                    """,
                arguments: [scope.serverKey, scope.userID, syncedAt]
            )
        }
    }

    func appendAlbums(_ albums: [Album], in scope: LibraryScope) throws {
        try database.write { db in
            try Self.save(albums: albums, db: db, scope: scope)
        }
    }

    func appendArtists(_ artists: [Artist], in scope: LibraryScope) throws {
        try database.write { db in
            try Self.save(artists: artists, db: db, scope: scope)
        }
    }

    // MARK: - Recently played

    func cachedRecentTracks(in scope: LibraryScope, limit: Int = 20) -> [Track] {
        do {
            return try database.read { db in
                let records = try LibraryItemRecord.fetchAll(
                    db,
                    sql: """
                        SELECT item.*
                        FROM userItemState AS state
                        JOIN libraryItem AS item
                          ON item.serverKey = state.serverKey
                         AND item.userID = state.userID
                         AND item.itemID = state.itemID
                        WHERE state.serverKey = ?
                          AND state.userID = ?
                          AND state.lastPlayedAt IS NOT NULL
                          AND item.itemType = ?
                        ORDER BY state.lastPlayedAt DESC
                        LIMIT ?
                        """,
                    arguments: [scope.serverKey, scope.userID, LibraryItemType.track.rawValue, limit]
                )
                let favorites = try Self.favoriteItemIDs(db, scope: scope)
                return records.map { $0.track(isFavorite: favorites.contains($0.itemID)) }
            }
        } catch {
            logger.error("Unable to load recent tracks: \(error.localizedDescription)")
            return []
        }
    }

    func replaceRecentlyPlayed(_ entries: [RecentTrackEntry], in scope: LibraryScope) {
        do {
            try database.write { db in
                // Jellyfin is canonical when reachable. Entries outside its
                // returned window stop participating in recency queries, while
                // their metadata remains useful to the rest of the cache.
                try db.execute(
                    sql: """
                        UPDATE userItemState
                        SET lastPlayedAt = NULL
                        WHERE serverKey = ? AND userID = ?
                          AND itemID IN (
                            SELECT itemID FROM libraryItem
                            WHERE serverKey = ? AND userID = ? AND itemType = ?
                          )
                        """,
                    arguments: [
                        scope.serverKey,
                        scope.userID,
                        scope.serverKey,
                        scope.userID,
                        LibraryItemType.track.rawValue
                    ]
                )

                for entry in entries {
                    try Self.save(track: entry.track, db: db, scope: scope)
                    try Self.updateUserState(
                        db,
                        scope: scope,
                        itemID: entry.track.id,
                        isFavorite: entry.track.isFavorite,
                        lastPlayedAt: entry.playedAt,
                        playCount: entry.playCount,
                        playbackPositionTicks: entry.playbackPositionTicks
                    )
                }
            }
        } catch {
            logger.error("Unable to replace recent tracks: \(error.localizedDescription)")
        }
    }

    func recordLocalPlay(_ track: Track, in scope: LibraryScope, playedAt: Date = Date()) {
        do {
            try database.write { db in
                try Self.save(track: track, db: db, scope: scope)
                try Self.updateUserState(
                    db,
                    scope: scope,
                    itemID: track.id,
                    lastPlayedAt: playedAt
                )
            }
        } catch {
            logger.error("Unable to persist local play: \(error.localizedDescription)")
        }
    }

    func cachedRecentAlbums(in scope: LibraryScope, limit: Int = 20) -> [Album] {
        var seen = Set<String>()
        return cachedRecentTracks(in: scope, limit: max(limit * 3, 50)).compactMap { track in
            guard let albumID = track.albumId,
                  !albumID.isEmpty,
                  seen.insert(albumID).inserted else {
                return nil
            }
            return Album(
                id: albumID,
                name: track.albumName,
                artistName: track.artistName,
                artistId: track.artistId,
                year: track.productionYear,
                artworkURL: track.artworkURL,
                isFavorite: false
            )
        }.prefix(limit).map { $0 }
    }

    // MARK: - Favorites

    func favoriteSnapshot(in scope: LibraryScope) -> FavoritesSnapshot {
        do {
            return try database.read { db in
                let records = try LibraryItemRecord.fetchAll(
                    db,
                    sql: """
                        SELECT item.*
                        FROM userItemState AS state
                        JOIN libraryItem AS item
                          ON item.serverKey = state.serverKey
                         AND item.userID = state.userID
                         AND item.itemID = state.itemID
                        WHERE state.serverKey = ?
                          AND state.userID = ?
                          AND state.isFavorite = 1
                        ORDER BY item.itemType, item.artistName COLLATE NOCASE, item.name COLLATE NOCASE
                        """,
                    arguments: [scope.serverKey, scope.userID]
                )

                var snapshot = FavoritesSnapshot.empty
                for record in records {
                    switch record.itemType {
                    case LibraryItemType.track.rawValue:
                        snapshot.tracks.append(record.track(isFavorite: true))
                    case LibraryItemType.album.rawValue:
                        snapshot.albums.append(record.album(isFavorite: true))
                    case LibraryItemType.artist.rawValue:
                        snapshot.artists.append(record.artist(isFavorite: true))
                    default:
                        break
                    }
                }
                return snapshot
            }
        } catch {
            logger.error("Unable to load cached favorites: \(error.localizedDescription)")
            return .empty
        }
    }

    func replaceFavorites(_ snapshot: FavoritesSnapshot, in scope: LibraryScope) {
        do {
            try database.write { db in
                try db.execute(
                    sql: """
                        UPDATE userItemState
                        SET isFavorite = 0
                        WHERE serverKey = ? AND userID = ?
                          AND itemID IN (
                            SELECT itemID FROM libraryItem
                            WHERE serverKey = ? AND userID = ?
                              AND itemType IN (?, ?, ?)
                          )
                        """,
                    arguments: [
                        scope.serverKey,
                        scope.userID,
                        scope.serverKey,
                        scope.userID,
                        LibraryItemType.track.rawValue,
                        LibraryItemType.album.rawValue,
                        LibraryItemType.artist.rawValue
                    ]
                )
                for track in snapshot.tracks {
                    try Self.save(track: track, db: db, scope: scope)
                    try Self.updateUserState(db, scope: scope, itemID: track.id, isFavorite: true)
                }
                for album in snapshot.albums {
                    try Self.save(album: album, db: db, scope: scope)
                    try Self.updateUserState(db, scope: scope, itemID: album.id, isFavorite: true)
                }
                for artist in snapshot.artists {
                    try Self.save(artist: artist, db: db, scope: scope)
                    try Self.updateUserState(db, scope: scope, itemID: artist.id, isFavorite: true)
                }
            }
        } catch {
            logger.error("Unable to replace favorites: \(error.localizedDescription)")
        }
    }

    func setFavorite(_ isFavorite: Bool, for track: Track, in scope: LibraryScope) {
        persistFavorite(isFavorite, itemID: track.id, scope: scope) { db in
            try Self.save(track: track, db: db, scope: scope)
        }
    }

    func setFavorite(_ isFavorite: Bool, for album: Album, in scope: LibraryScope) {
        persistFavorite(isFavorite, itemID: album.id, scope: scope) { db in
            try Self.save(album: album, db: db, scope: scope)
        }
    }

    func setFavorite(_ isFavorite: Bool, for artist: Artist, in scope: LibraryScope) {
        persistFavorite(isFavorite, itemID: artist.id, scope: scope) { db in
            try Self.save(artist: artist, db: db, scope: scope)
        }
    }

    // MARK: - UserDefaults migration

    /// Imports the old JSON blobs transactionally, then removes them only after
    /// SQLite has committed the equivalent rows.
    func importLegacyCacheIfNeeded(in scope: LibraryScope) {
        let defaults = UserDefaults.standard
        let decoder = JSONDecoder()
        let albums = defaults.data(forKey: "cachedAlbums")
            .flatMap { try? decoder.decode([Album].self, from: $0) } ?? []
        let artists = defaults.data(forKey: "cachedArtists")
            .flatMap { try? decoder.decode([Artist].self, from: $0) } ?? []
        let playlists = defaults.data(forKey: "cachedPlaylists")
            .flatMap { try? decoder.decode([Playlist].self, from: $0) } ?? []
        let recentTracks = defaults.data(forKey: "playerState_recentTracks")
            .flatMap { try? decoder.decode([Track].self, from: $0) } ?? []

        guard !albums.isEmpty || !artists.isEmpty || !playlists.isEmpty || !recentTracks.isEmpty else {
            defaults.removeObject(forKey: "recentlyPlayedAlbumIds")
            return
        }

        do {
            let alreadyHasLibrary = try database.read { db in
                try Bool.fetchOne(
                    db,
                    sql: """
                        SELECT EXISTS(
                            SELECT 1 FROM librarySyncState
                            WHERE serverKey = ? AND userID = ?
                        )
                        """,
                    arguments: [scope.serverKey, scope.userID]
                ) ?? false
            }

            try database.write { db in
                if !alreadyHasLibrary && (!albums.isEmpty || !artists.isEmpty || !playlists.isEmpty) {
                    try Self.save(albums: albums, db: db, scope: scope)
                    try Self.save(artists: artists, db: db, scope: scope)
                    try Self.save(playlists: playlists, db: db, scope: scope)
                    try db.execute(
                        sql: """
                            INSERT INTO librarySyncState (serverKey, userID, librarySyncedAt)
                            VALUES (?, ?, ?)
                            ON CONFLICT(serverKey, userID) DO NOTHING
                            """,
                        arguments: [scope.serverKey, scope.userID, Date()]
                    )
                }

                let newest = Date()
                for (index, track) in recentTracks.enumerated() {
                    try Self.save(track: track, db: db, scope: scope)
                    try Self.updateUserState(
                        db,
                        scope: scope,
                        itemID: track.id,
                        isFavorite: track.isFavorite,
                        lastPlayedAt: newest.addingTimeInterval(-Double(index))
                    )
                }
            }

            defaults.removeObject(forKey: "cachedAlbums")
            defaults.removeObject(forKey: "cachedArtists")
            defaults.removeObject(forKey: "cachedPlaylists")
            defaults.removeObject(forKey: "playerState_recentTracks")
            defaults.removeObject(forKey: "recentlyPlayedAlbumIds")
        } catch {
            logger.error("Legacy cache migration failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Private helpers

    private func persistFavorite(
        _ isFavorite: Bool,
        itemID: String,
        scope: LibraryScope,
        saveItem: (Database) throws -> Void
    ) {
        do {
            try database.write { db in
                try saveItem(db)
                try Self.updateUserState(
                    db,
                    scope: scope,
                    itemID: itemID,
                    isFavorite: isFavorite
                )
            }
        } catch {
            logger.error("Unable to persist favorite state: \(error.localizedDescription)")
        }
    }

    private static func defaultDatabaseURL() throws -> URL {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return applicationSupport
            .appendingPathComponent("JellyAmp", isDirectory: true)
            .appendingPathComponent("Library.sqlite", isDirectory: false)
    }

    private static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createLibraryCache") { db in
            try db.create(table: "libraryItem") { table in
                table.column("serverKey", .text).notNull()
                table.column("userID", .text).notNull()
                table.column("itemID", .text).notNull()
                table.column("itemType", .text).notNull()
                table.column("name", .text).notNull()
                table.column("artistName", .text)
                table.column("artistID", .text)
                table.column("albumName", .text)
                table.column("albumID", .text)
                table.column("productionYear", .integer)
                table.column("duration", .double)
                table.column("artworkURL", .text)
                table.column("indexNumber", .integer)
                table.column("parentIndexNumber", .integer)
                table.column("trackCount", .integer)
                table.column("albumCount", .integer)
                table.column("biography", .text)
                table.column("dateCreated", .datetime)
                table.column("updatedAt", .datetime).notNull()
                table.primaryKey(["serverKey", "userID", "itemID"])
            }

            try db.create(table: "userItemState") { table in
                table.column("serverKey", .text).notNull()
                table.column("userID", .text).notNull()
                table.column("itemID", .text).notNull()
                table.column("lastPlayedAt", .datetime)
                table.column("playCount", .integer)
                table.column("isFavorite", .boolean)
                table.column("playbackPositionTicks", .integer)
                table.primaryKey(["serverKey", "userID", "itemID"])
            }

            try db.create(table: "librarySyncState") { table in
                table.column("serverKey", .text).notNull()
                table.column("userID", .text).notNull()
                table.column("librarySyncedAt", .datetime).notNull()
                table.primaryKey(["serverKey", "userID"])
            }

            try db.execute(sql: """
                CREATE INDEX libraryItem_type_name
                ON libraryItem(serverKey, userID, itemType, name COLLATE NOCASE)
                """)
            try db.execute(sql: """
                CREATE INDEX libraryItem_album
                ON libraryItem(serverKey, userID, albumID)
                WHERE albumID IS NOT NULL
                """)
            try db.execute(sql: """
                CREATE INDEX userItemState_recent
                ON userItemState(serverKey, userID, lastPlayedAt DESC)
                WHERE lastPlayedAt IS NOT NULL
                """)
            try db.execute(sql: """
                CREATE INDEX userItemState_favorite
                ON userItemState(serverKey, userID, isFavorite)
                WHERE isFavorite = 1
                """)
        }
        return migrator
    }

    private static func items(
        _ db: Database,
        scope: LibraryScope,
        type: LibraryItemType
    ) throws -> [LibraryItemRecord] {
        try LibraryItemRecord.fetchAll(
            db,
            sql: """
                SELECT * FROM libraryItem
                WHERE serverKey = ? AND userID = ? AND itemType = ?
                ORDER BY name COLLATE NOCASE
                """,
            arguments: [scope.serverKey, scope.userID, type.rawValue]
        )
    }

    private static func favoriteItemIDs(_ db: Database, scope: LibraryScope) throws -> Set<String> {
        Set(try String.fetchAll(
            db,
            sql: """
                SELECT itemID FROM userItemState
                WHERE serverKey = ? AND userID = ? AND isFavorite = 1
                """,
            arguments: [scope.serverKey, scope.userID]
        ))
    }

    private static func save(albums: [Album], db: Database, scope: LibraryScope) throws {
        for album in albums { try save(album: album, db: db, scope: scope) }
    }

    private static func save(artists: [Artist], db: Database, scope: LibraryScope) throws {
        for artist in artists { try save(artist: artist, db: db, scope: scope) }
    }

    private static func save(playlists: [Playlist], db: Database, scope: LibraryScope) throws {
        for playlist in playlists { try save(playlist: playlist, db: db, scope: scope) }
    }

    private static func save(album: Album, db: Database, scope: LibraryScope) throws {
        try LibraryItemRecord(album: album, scope: scope).save(db)
        try updateUserState(db, scope: scope, itemID: album.id, isFavorite: album.isFavorite)
    }

    private static func save(artist: Artist, db: Database, scope: LibraryScope) throws {
        try LibraryItemRecord(artist: artist, scope: scope).save(db)
        try updateUserState(db, scope: scope, itemID: artist.id, isFavorite: artist.isFavorite)
    }

    private static func save(playlist: Playlist, db: Database, scope: LibraryScope) throws {
        try LibraryItemRecord(playlist: playlist, scope: scope).save(db)
        try updateUserState(db, scope: scope, itemID: playlist.id, isFavorite: playlist.isFavorite)
    }

    private static func save(track: Track, db: Database, scope: LibraryScope) throws {
        try LibraryItemRecord(track: track, scope: scope).save(db)
    }

    private static func updateUserState(
        _ db: Database,
        scope: LibraryScope,
        itemID: String,
        isFavorite: Bool? = nil,
        lastPlayedAt: Date? = nil,
        playCount: Int? = nil,
        playbackPositionTicks: Int64? = nil
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO userItemState (
                    serverKey, userID, itemID, lastPlayedAt, playCount,
                    isFavorite, playbackPositionTicks
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(serverKey, userID, itemID) DO UPDATE SET
                    lastPlayedAt = COALESCE(excluded.lastPlayedAt, userItemState.lastPlayedAt),
                    playCount = COALESCE(excluded.playCount, userItemState.playCount),
                    isFavorite = COALESCE(excluded.isFavorite, userItemState.isFavorite),
                    playbackPositionTicks = COALESCE(
                        excluded.playbackPositionTicks,
                        userItemState.playbackPositionTicks
                    )
                """,
            arguments: [
                scope.serverKey,
                scope.userID,
                itemID,
                lastPlayedAt,
                playCount,
                isFavorite,
                playbackPositionTicks
            ]
        )
    }
}

nonisolated private enum LibraryItemType: String, Sendable {
    case track
    case album
    case artist
    case playlist
}

nonisolated private struct LibraryItemRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "libraryItem"

    let serverKey: String
    let userID: String
    let itemID: String
    let itemType: String
    let name: String
    let artistName: String?
    let artistID: String?
    let albumName: String?
    let albumID: String?
    let productionYear: Int?
    let duration: Double?
    let artworkURL: String?
    let indexNumber: Int?
    let parentIndexNumber: Int?
    let trackCount: Int?
    let albumCount: Int?
    let biography: String?
    let dateCreated: Date?
    let updatedAt: Date

    init(track: Track, scope: LibraryScope) {
        serverKey = scope.serverKey
        userID = scope.userID
        itemID = track.id
        itemType = LibraryItemType.track.rawValue
        name = track.name
        artistName = track.artistName
        artistID = track.artistId
        albumName = track.albumName
        albumID = track.albumId
        productionYear = track.productionYear
        duration = track.duration
        artworkURL = track.artworkURL
        indexNumber = track.indexNumber
        parentIndexNumber = track.parentIndexNumber
        trackCount = nil
        albumCount = nil
        biography = nil
        dateCreated = nil
        updatedAt = Date()
    }

    init(album: Album, scope: LibraryScope) {
        serverKey = scope.serverKey
        userID = scope.userID
        itemID = album.id
        itemType = LibraryItemType.album.rawValue
        name = album.name
        artistName = album.artistName
        artistID = album.artistId
        albumName = nil
        albumID = nil
        productionYear = album.year
        duration = nil
        artworkURL = album.artworkURL
        indexNumber = nil
        parentIndexNumber = nil
        trackCount = album.trackCount
        albumCount = nil
        biography = nil
        dateCreated = nil
        updatedAt = Date()
    }

    init(artist: Artist, scope: LibraryScope) {
        serverKey = scope.serverKey
        userID = scope.userID
        itemID = artist.id
        itemType = LibraryItemType.artist.rawValue
        name = artist.name
        artistName = nil
        artistID = nil
        albumName = nil
        albumID = nil
        productionYear = nil
        duration = nil
        artworkURL = artist.artworkURL
        indexNumber = nil
        parentIndexNumber = nil
        trackCount = nil
        albumCount = artist.albumCount
        biography = artist.bio
        dateCreated = nil
        updatedAt = Date()
    }

    init(playlist: Playlist, scope: LibraryScope) {
        serverKey = scope.serverKey
        userID = scope.userID
        itemID = playlist.id
        itemType = LibraryItemType.playlist.rawValue
        name = playlist.name
        artistName = nil
        artistID = nil
        albumName = nil
        albumID = nil
        productionYear = nil
        duration = nil
        artworkURL = playlist.artworkURL
        indexNumber = nil
        parentIndexNumber = nil
        trackCount = playlist.trackCount
        albumCount = nil
        biography = nil
        dateCreated = playlist.dateCreated
        updatedAt = Date()
    }

    func track(isFavorite: Bool) -> Track {
        Track(
            id: itemID,
            name: name,
            artistName: artistName ?? "Unknown Artist",
            albumName: albumName ?? "Unknown Album",
            duration: duration ?? 0,
            artworkURL: artworkURL,
            isFavorite: isFavorite,
            indexNumber: indexNumber,
            parentIndexNumber: parentIndexNumber,
            albumId: albumID,
            artistId: artistID,
            productionYear: productionYear
        )
    }

    func album(isFavorite: Bool) -> Album {
        Album(
            id: itemID,
            name: name,
            artistName: artistName ?? "Unknown Artist",
            artistId: artistID,
            year: productionYear,
            trackCount: trackCount,
            artworkURL: artworkURL,
            isFavorite: isFavorite
        )
    }

    func artist(isFavorite: Bool) -> Artist {
        Artist(
            id: itemID,
            name: name,
            bio: biography,
            albumCount: albumCount ?? 0,
            artworkURL: artworkURL,
            isFavorite: isFavorite
        )
    }

    func playlist(isFavorite: Bool) -> Playlist {
        Playlist(
            id: itemID,
            name: name,
            trackCount: trackCount ?? 0,
            artworkURL: artworkURL,
            dateCreated: dateCreated,
            isFavorite: isFavorite
        )
    }
}
