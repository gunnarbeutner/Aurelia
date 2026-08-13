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

    private init(serverKey: String, userID: String) {
        self.serverKey = serverKey
        self.userID = userID
    }

    /// Scope a full sync accumulates into before it is promoted. Jellyfin user
    /// IDs are GUIDs, so the suffix cannot collide with a live scope, and every
    /// read filters on the exact pair — staged rows stay invisible to the UI.
    var staging: LibraryScope {
        LibraryScope(serverKey: serverKey, userID: userID + "|staging")
    }
}

/// Where a resumable full sync left off. `detail` carries the playlist being
/// paged while the sync is in the playlist-entry stage.
nonisolated struct LibraryStagingProgress: Equatable, Sendable {
    let stage: String
    let nextOffset: Int
    let detail: String?
    let startedAt: Date
}

nonisolated struct LibrarySnapshot: Sendable {
    let albums: [Album]
    let artists: [Artist]
    let tracks: [Track]
    let playlists: [Playlist]
    let genres: [Genre]
    let lastSyncedAt: Date?
    let revision: Int64

    var hasCachedLibrary: Bool { lastSyncedAt != nil }
}

nonisolated struct LibrarySyncState: Equatable, Sendable {
    let librarySyncedAt: Date
    let metadataWatermark: Date
    let userDataWatermark: Date
    let lastReconciledAt: Date?
    let catalogRevision: Int64
}

nonisolated struct LibraryPlaylistEntry: Hashable, Sendable {
    let playlistID: String
    let track: Track
    let position: Int
}

nonisolated struct LibraryCatalog: Sendable {
    let albums: [Album]
    let artists: [Artist]
    let tracks: [Track]
    let playlists: [Playlist]
    let genres: [Genre]
    let playlistEntries: [LibraryPlaylistEntry]
    let userData: [LibraryUserDataChange]

    init(
        albums: [Album],
        artists: [Artist],
        tracks: [Track],
        playlists: [Playlist],
        genres: [Genre],
        playlistEntries: [LibraryPlaylistEntry],
        userData: [LibraryUserDataChange] = []
    ) {
        self.albums = albums
        self.artists = artists
        self.tracks = tracks
        self.playlists = playlists
        self.genres = genres
        self.playlistEntries = playlistEntries
        self.userData = userData
    }
}

/// One transactional update to the local catalog. Reference inventories are
/// optional because artists and genres are reconciled less frequently than
/// ordinary item metadata.
nonisolated struct LibraryDelta: Sendable {
    var albums: [Album] = []
    var artists: [Artist] = []
    var tracks: [Track] = []
    var playlists: [Playlist] = []
    var genres: [Genre] = []
    var userData: [LibraryUserDataChange] = []
    var refreshedPlaylistIDs = Set<String>()
    var playlistEntries: [LibraryPlaylistEntry] = []
    var removedItemIDs = Set<String>()
    var replacementArtists: [Artist]?
    var replacementGenres: [Genre]?
    var metadataWatermark: Date
    var userDataWatermark: Date
    var reconciledAt: Date?

    init(
        albums: [Album] = [],
        artists: [Artist] = [],
        tracks: [Track] = [],
        playlists: [Playlist] = [],
        genres: [Genre] = [],
        userData: [LibraryUserDataChange] = [],
        refreshedPlaylistIDs: Set<String> = [],
        playlistEntries: [LibraryPlaylistEntry] = [],
        removedItemIDs: Set<String> = [],
        replacementArtists: [Artist]? = nil,
        replacementGenres: [Genre]? = nil,
        metadataWatermark: Date,
        userDataWatermark: Date,
        reconciledAt: Date? = nil
    ) {
        self.albums = albums
        self.artists = artists
        self.tracks = tracks
        self.playlists = playlists
        self.genres = genres
        self.userData = userData
        self.refreshedPlaylistIDs = refreshedPlaylistIDs
        self.playlistEntries = playlistEntries
        self.removedItemIDs = removedItemIDs
        self.replacementArtists = replacementArtists
        self.replacementGenres = replacementGenres
        self.metadataWatermark = metadataWatermark
        self.userDataWatermark = userDataWatermark
        self.reconciledAt = reconciledAt
    }

    var changeCount: Int {
        albums.count + artists.count + tracks.count + playlists.count + genres.count
            + userData.count + removedItemIDs.count + refreshedPlaylistIDs.count
            + (replacementArtists?.count ?? 0) + (replacementGenres?.count ?? 0)
    }
}

nonisolated struct LibraryUserDataChange: Hashable, Sendable {
    let itemID: String
    let isFavorite: Bool?
    let lastPlayedAt: Date?
    let playCount: Int?
    let playbackPositionTicks: Int64?
}

nonisolated struct LibraryDeltaCommit: Sendable {
    let baseRevision: Int64
    let revision: Int64
    let changed: Bool
    let removedItemIDs: Set<String>
}

nonisolated enum LibrarySearchFilter: Sendable {
    case all
    case artists
    case albums
    case tracks
    case playlists
}

nonisolated enum LibrarySearchResult: Identifiable, Hashable, Sendable {
    case artist(Artist)
    case album(Album)
    case track(Track)
    case playlist(Playlist)

    var id: String {
        switch self {
        case .artist(let artist): return "artist:\(artist.id)"
        case .album(let album): return "album:\(album.id)"
        case .track(let track): return "track:\(track.id)"
        case .playlist(let playlist): return "playlist:\(playlist.id)"
        }
    }
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

nonisolated struct DiscoveryCandidate: Sendable, Equatable {
    let track: Track
    let lastPlayedAt: Date?
    let playCount: Int
    let isFavorite: Bool
}

nonisolated protocol DiscoveryCandidateProviding: Sendable {
    func discoveryCandidates(in scope: LibraryScope) async -> [DiscoveryCandidate]
}

/// SQLite-backed source of truth for the local Jellyfin metadata cache.
///
/// A single actor owns the pool-facing repository API. GRDB still uses a
/// DatabasePool internally, so observations and future background readers can
/// be added without changing the schema or the view-facing interface.
actor LibraryRepository: RecentTrackCaching, DiscoveryCandidateProviding {
    static let shared: LibraryRepository = {
        do {
            return try LibraryRepository(databaseURL: defaultDatabaseURL())
        } catch {
            fatalError("Unable to open the Aurelia library database: \(error)")
        }
    }()

    /// GRDB's pool is safe to use concurrently. Keep it reachable from
    /// nonisolated read entry points so UI reads do not wait behind this
    /// actor's potentially long-running sync commits.
    nonisolated private let database: DatabasePool
    private let logger = Logger(subsystem: "de.beutner.Aurelia", category: "LibraryRepository")

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

    func librarySnapshot(in scope: LibraryScope, includeTracks: Bool = true) throws -> LibrarySnapshot {
        try database.read { db in
            let favorites = try Self.favoriteItemIDs(db, scope: scope)
            let albums = try Self.items(db, scope: scope, type: .album)
                .map { $0.album(isFavorite: favorites.contains($0.itemID)) }
            let artists = try Self.browsableArtists(db, scope: scope)
                .map { $0.artist(isFavorite: favorites.contains($0.itemID)) }
            let tracks = includeTracks
                ? try Self.items(db, scope: scope, type: .track)
                    .map { $0.track(isFavorite: favorites.contains($0.itemID)) }
                : []
            let playlists = try Self.items(db, scope: scope, type: .playlist)
                .map { $0.playlist(isFavorite: favorites.contains($0.itemID)) }
            let genres = try Self.items(db, scope: scope, type: .genre)
                .map { $0.genre() }
            let syncRow = try Row.fetchOne(
                db,
                sql: """
                    SELECT librarySyncedAt, catalogRevision
                    FROM librarySyncState
                    WHERE serverKey = ? AND userID = ?
                    """,
                arguments: [scope.serverKey, scope.userID]
            )
            return LibrarySnapshot(
                albums: albums,
                artists: artists,
                tracks: tracks,
                playlists: playlists,
                genres: genres,
                lastSyncedAt: syncRow?["librarySyncedAt"],
                revision: syncRow?["catalogRevision"] ?? 0
            )
        }
    }

    func syncState(in scope: LibraryScope) throws -> LibrarySyncState? {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT librarySyncedAt, metadataWatermark, userDataWatermark,
                           lastReconciledAt, catalogRevision
                    FROM librarySyncState
                    WHERE serverKey = ? AND userID = ?
                    """,
                arguments: [scope.serverKey, scope.userID]
            ) else { return nil }
            let librarySyncedAt: Date = row["librarySyncedAt"]
            return LibrarySyncState(
                librarySyncedAt: librarySyncedAt,
                // The first post-migration delta deliberately overlaps the
                // prior successful sync. This closes the small window between
                // the server query and the old full-catalog commit.
                metadataWatermark: row["metadataWatermark"]
                    ?? librarySyncedAt.addingTimeInterval(-86_400),
                userDataWatermark: row["userDataWatermark"]
                    ?? librarySyncedAt.addingTimeInterval(-86_400),
                lastReconciledAt: row["lastReconciledAt"],
                catalogRevision: row["catalogRevision"] ?? 0
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
                    INSERT INTO librarySyncState (
                        serverKey, userID, librarySyncedAt,
                        metadataWatermark, userDataWatermark, lastReconciledAt,
                        catalogRevision
                    ) VALUES (?, ?, ?, ?, ?, ?, 1)
                    ON CONFLICT(serverKey, userID) DO UPDATE SET
                        librarySyncedAt = excluded.librarySyncedAt,
                        metadataWatermark = excluded.metadataWatermark,
                        userDataWatermark = excluded.userDataWatermark,
                        lastReconciledAt = excluded.lastReconciledAt,
                        catalogRevision = librarySyncState.catalogRevision + 1
                    """,
                arguments: [
                    scope.serverKey, scope.userID, syncedAt,
                    syncedAt, syncedAt, syncedAt
                ]
            )
        }
    }

    /// Atomically replaces every server-owned metadata row for a library. All
    /// network paging is completed before this method is called, so readers
    /// continue seeing the previous complete catalog if a request fails.
    func replaceCompleteLibrary(
        _ catalog: LibraryCatalog,
        in scope: LibraryScope,
        syncedAt: Date = Date()
    ) throws {
        try database.write { db in
            try Self.deleteCatalogRows(db, scope: scope)
            try Self.write(catalog: catalog, db: db, scope: scope)

            try Self.rebuildSearchIndex(db, scope: scope)
            try db.execute(
                sql: """
                    INSERT INTO librarySyncState (
                        serverKey, userID, librarySyncedAt,
                        metadataWatermark, userDataWatermark, lastReconciledAt,
                        catalogRevision
                    ) VALUES (?, ?, ?, ?, ?, ?, 1)
                    ON CONFLICT(serverKey, userID) DO UPDATE SET
                        librarySyncedAt = excluded.librarySyncedAt,
                        metadataWatermark = excluded.metadataWatermark,
                        userDataWatermark = excluded.userDataWatermark,
                        lastReconciledAt = excluded.lastReconciledAt,
                        catalogRevision = librarySyncState.catalogRevision + 1
                    """,
                arguments: [
                    scope.serverKey, scope.userID, syncedAt,
                    syncedAt, syncedAt, syncedAt
                ]
            )
        }
    }

    /// Writes catalog rows and their relationships into `scope`. Shared by the
    /// one-shot full replace and by staged page-at-a-time accumulation, so both
    /// paths produce byte-identical rows.
    private static func write(
        catalog: LibraryCatalog,
        db: Database,
        scope: LibraryScope
    ) throws {
            try Self.save(albums: catalog.albums, db: db, scope: scope)
            try Self.save(artists: catalog.artists, db: db, scope: scope)
            try Self.save(tracks: catalog.tracks, db: db, scope: scope)
            try Self.save(playlists: catalog.playlists, db: db, scope: scope)
            try Self.save(genres: catalog.genres, db: db, scope: scope)

            for album in catalog.albums {
                if let artistID = album.artistId {
                    try Self.saveArtistLink(
                        itemID: album.id,
                        artistID: artistID,
                        position: 0,
                        db: db,
                        scope: scope
                    )
                }
                for genreID in album.genreIDs ?? [] {
                    try Self.saveGenreLink(itemID: album.id, genreID: genreID, db: db, scope: scope)
                }
            }

            for track in catalog.tracks {
                let artistIDs = track.artistIDs ?? track.artistId.map { [$0] } ?? []
                for (position, artistID) in artistIDs.enumerated() {
                    try Self.saveArtistLink(
                        itemID: track.id,
                        artistID: artistID,
                        position: position,
                        db: db,
                        scope: scope
                    )
                }
                for genreID in track.genreIDs ?? [] {
                    try Self.saveGenreLink(itemID: track.id, genreID: genreID, db: db, scope: scope)
                }
            }

            for entry in catalog.playlistEntries {
                try Self.save(track: entry.track, db: db, scope: scope)
                try db.execute(
                    sql: """
                        INSERT INTO playlistEntry (
                            serverKey, userID, playlistID, itemID, entryID, position
                        ) VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(serverKey, userID, playlistID, itemID) DO UPDATE SET
                            entryID = excluded.entryID,
                            position = excluded.position
                        """,
                    arguments: [
                        scope.serverKey,
                        scope.userID,
                        entry.playlistID,
                        entry.track.id,
                        entry.track.playlistEntryID,
                        entry.position
                    ]
                )
            }

            // The initial catalog response already contains Jellyfin user
            // state. Persist all of it during the same transaction so the
            // first SQLite-backed UI snapshot does not need a second pass to
            // recover favorites, play history, or resume positions.
            for change in catalog.userData {
                try Self.updateUserState(
                    db,
                    scope: scope,
                    itemID: change.itemID,
                    isFavorite: change.isFavorite,
                    lastPlayedAt: change.lastPlayedAt,
                    playCount: change.playCount,
                    playbackPositionTicks: change.playbackPositionTicks
                )
            }
    }

    // MARK: - Resumable full sync

    /// Where an interrupted full sync left off, or nil when none is staged.
    func stagingProgress(in scope: LibraryScope) throws -> LibraryStagingProgress? {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT stage, nextOffset, detail, startedAt
                    FROM librarySyncProgress
                    WHERE serverKey = ? AND userID = ?
                    """,
                arguments: [scope.serverKey, scope.userID]
            ) else { return nil }
            return LibraryStagingProgress(
                stage: row["stage"],
                nextOffset: row["nextOffset"],
                detail: row["detail"],
                startedAt: row["startedAt"]
            )
        }
    }

    /// Discards a partial sync so the next one starts from a clean slate.
    func resetStagedLibrary(in scope: LibraryScope) throws {
        let staging = scope.staging
        try database.write { db in
            try Self.deleteCatalogRows(db, scope: staging)
            try db.execute(
                sql: "DELETE FROM librarySyncProgress WHERE serverKey = ? AND userID = ?",
                arguments: [scope.serverKey, scope.userID]
            )
        }
    }

    /// Persists one page into the staging scope and advances the cursor in the
    /// same transaction, so the recorded position never runs ahead of the rows.
    func appendStagedChunk(
        _ chunk: LibraryCatalog,
        stage: String,
        nextOffset: Int,
        detail: String?,
        startedAt: Date,
        in scope: LibraryScope
    ) throws {
        let staging = scope.staging
        try database.write { db in
            try Self.write(catalog: chunk, db: db, scope: staging)
            try db.execute(
                sql: """
                    INSERT INTO librarySyncProgress (
                        serverKey, userID, stage, nextOffset, detail, startedAt
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(serverKey, userID) DO UPDATE SET
                        stage = excluded.stage,
                        nextOffset = excluded.nextOffset,
                        detail = excluded.detail
                    """,
                arguments: [
                    scope.serverKey, scope.userID,
                    stage, nextOffset, detail, startedAt
                ]
            )
        }
    }

    /// Playlist IDs already staged, ordered deterministically so a resumed sync
    /// walks them in the same order it did before being interrupted.
    func stagedPlaylistIDs(in scope: LibraryScope) throws -> [String] {
        let staging = scope.staging
        return try database.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT itemID FROM libraryItem
                    WHERE serverKey = ? AND userID = ? AND itemType = ?
                    ORDER BY itemID
                    """,
                arguments: [
                    staging.serverKey,
                    staging.userID,
                    LibraryItemType.playlist.rawValue
                ]
            )
        }
    }

    /// Promotes a fully staged catalog in one transaction: the live rows are
    /// replaced by re-keying the staged rows, so readers see either the previous
    /// complete catalog or the new one, never a partial merge.
    func promoteStagedLibrary(in scope: LibraryScope, syncedAt: Date) throws {
        let staging = scope.staging
        try database.write { db in
            try Self.deleteCatalogRows(db, scope: scope)

            for table in ["libraryItem", "userItemState", "itemArtist", "itemGenre", "playlistEntry"] {
                try db.execute(
                    sql: """
                        UPDATE \(table) SET userID = ?
                        WHERE serverKey = ? AND userID = ?
                        """,
                    arguments: [scope.userID, staging.serverKey, staging.userID]
                )
            }

            try Self.rebuildSearchIndex(db, scope: scope)
            try db.execute(
                sql: """
                    INSERT INTO librarySyncState (
                        serverKey, userID, librarySyncedAt,
                        metadataWatermark, userDataWatermark, lastReconciledAt,
                        catalogRevision
                    ) VALUES (?, ?, ?, ?, ?, ?, 1)
                    ON CONFLICT(serverKey, userID) DO UPDATE SET
                        librarySyncedAt = excluded.librarySyncedAt,
                        metadataWatermark = excluded.metadataWatermark,
                        userDataWatermark = excluded.userDataWatermark,
                        lastReconciledAt = excluded.lastReconciledAt,
                        catalogRevision = librarySyncState.catalogRevision + 1
                    """,
                arguments: [
                    scope.serverKey, scope.userID, syncedAt,
                    syncedAt, syncedAt, syncedAt
                ]
            )
            try db.execute(
                sql: "DELETE FROM librarySyncProgress WHERE serverKey = ? AND userID = ?",
                arguments: [scope.serverKey, scope.userID]
            )
        }
    }

    private static func deleteCatalogRows(_ db: Database, scope: LibraryScope) throws {
        for table in [
            "itemArtist", "itemGenre", "playlistEntry",
            "libraryItemFTS", "libraryItem", "userItemState"
        ] {
            try db.execute(
                sql: "DELETE FROM \(table) WHERE serverKey = ? AND userID = ?",
                arguments: [scope.serverKey, scope.userID]
            )
        }
    }

    /// Applies a routine Jellyfin delta as one SQLite transaction. UI readers
    /// see either the previous revision or the complete new revision.
    func applyDelta(_ delta: LibraryDelta, in scope: LibraryScope) throws -> LibraryDeltaCommit {
        try database.write { db in
            let baseRevision = try Int64.fetchOne(
                db,
                sql: """
                    SELECT catalogRevision FROM librarySyncState
                    WHERE serverKey = ? AND userID = ?
                    """,
                arguments: [scope.serverKey, scope.userID]
            ) ?? 0
            var removed = delta.removedItemIDs
            if let replacementArtists = delta.replacementArtists {
                let current = try Self.itemIDs(db, scope: scope, type: .artist)
                removed.formUnion(current.subtracting(replacementArtists.map(\.id)))
            }
            if let replacementGenres = delta.replacementGenres {
                let current = try Self.itemIDs(db, scope: scope, type: .genre)
                removed.formUnion(current.subtracting(replacementGenres.map(\.id)))
            }
            let changed = delta.changeCount > 0
                || !removed.isEmpty
                || delta.replacementArtists != nil
                || delta.replacementGenres != nil
            let revision = changed ? baseRevision + 1 : baseRevision
            for itemID in removed {
                try Self.deleteItem(itemID, db: db, scope: scope)
            }

            let artists = delta.replacementArtists ?? delta.artists
            let genres = delta.replacementGenres ?? delta.genres
            for artist in artists {
                try LibraryItemRecord(artist: artist, scope: scope).save(db)
            }
            for genre in genres {
                try LibraryItemRecord(genre: genre, scope: scope).save(db)
            }
            for album in delta.albums {
                try LibraryItemRecord(album: album, scope: scope).save(db)
                try Self.replaceRelations(for: album, db: db, scope: scope)
            }
            for track in delta.tracks {
                try LibraryItemRecord(track: track, scope: scope).save(db)
                try Self.replaceRelations(for: track, db: db, scope: scope)
            }
            for playlist in delta.playlists {
                try LibraryItemRecord(playlist: playlist, scope: scope).save(db)
            }

            for playlistID in delta.refreshedPlaylistIDs {
                try db.execute(
                    sql: "DELETE FROM playlistEntry WHERE serverKey = ? AND userID = ? AND playlistID = ?",
                    arguments: [scope.serverKey, scope.userID, playlistID]
                )
            }
            for entry in delta.playlistEntries {
                try LibraryItemRecord(track: entry.track, scope: scope).save(db)
                try db.execute(
                    sql: """
                        INSERT INTO playlistEntry (
                            serverKey, userID, playlistID, itemID, entryID, position
                        ) VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(serverKey, userID, playlistID, itemID) DO UPDATE SET
                            entryID = excluded.entryID,
                            position = excluded.position
                        """,
                    arguments: [
                        scope.serverKey, scope.userID, entry.playlistID,
                        entry.track.id, entry.track.playlistEntryID, entry.position
                    ]
                )
            }

            for change in delta.userData {
                try Self.updateUserState(
                    db,
                    scope: scope,
                    itemID: change.itemID,
                    isFavorite: change.isFavorite,
                    lastPlayedAt: change.lastPlayedAt,
                    playCount: change.playCount,
                    playbackPositionTicks: change.playbackPositionTicks
                )
            }

            let changedIDs = Set(delta.albums.map(\.id))
                .union(artists.map(\.id))
                .union(delta.tracks.map(\.id))
                .union(delta.playlists.map(\.id))
                .union(genres.map(\.id))
                .union(delta.playlistEntries.map(\.track.id))
            try Self.refreshSearchIndex(
                itemIDs: changedIDs.union(removed),
                db: db,
                scope: scope
            )

            let completedAt = Date()
            try db.execute(
                sql: """
                    INSERT INTO librarySyncState (
                        serverKey, userID, librarySyncedAt,
                        metadataWatermark, userDataWatermark, lastReconciledAt,
                        catalogRevision
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(serverKey, userID) DO UPDATE SET
                        librarySyncedAt = excluded.librarySyncedAt,
                        metadataWatermark = excluded.metadataWatermark,
                        userDataWatermark = excluded.userDataWatermark,
                        lastReconciledAt = COALESCE(
                            excluded.lastReconciledAt,
                            librarySyncState.lastReconciledAt
                        ),
                        catalogRevision = excluded.catalogRevision
                    """,
                arguments: [
                    scope.serverKey, scope.userID, completedAt,
                    delta.metadataWatermark, delta.userDataWatermark,
                    delta.reconciledAt, revision
                ]
            )
            return LibraryDeltaCommit(
                baseRevision: baseRevision,
                revision: revision,
                changed: changed,
                removedItemIDs: removed
            )
        }
    }

    func primaryCatalogItemIDs(in scope: LibraryScope) throws -> Set<String> {
        try database.read { db in
            Set(try String.fetchAll(
                db,
                sql: """
                    SELECT itemID FROM libraryItem
                    WHERE serverKey = ? AND userID = ?
                      AND itemType IN (?, ?, ?)
                    """,
                arguments: [
                    scope.serverKey, scope.userID,
                    LibraryItemType.track.rawValue,
                    LibraryItemType.album.rawValue,
                    LibraryItemType.playlist.rawValue
                ]
            ))
        }
    }

    /// Maps a set of downloaded tracks onto the containers they belong to, so
    /// browsing can mark albums, artists and playlists that hold nothing
    /// playable while the server is out of reach. Membership is read from the
    /// catalog rather than from the download records because a download only
    /// remembers one artist, while a track can credit several.
    func offlineContainers(
        forTrackIDs trackIDs: Set<String>,
        in scope: LibraryScope
    ) throws -> OfflineContainerIDs {
        guard !trackIDs.isEmpty else { return OfflineContainerIDs() }
        return try database.read { db in
            var result = OfflineContainerIDs()

            try Self.forEachIDBatch(trackIDs) { slots, arguments in
                result.albumIDs.formUnion(try String.fetchAll(
                    db,
                    sql: """
                        SELECT DISTINCT albumID FROM libraryItem
                        WHERE serverKey = ? AND userID = ?
                          AND albumID IS NOT NULL AND itemID IN (\(slots))
                        """,
                    arguments: StatementArguments([scope.serverKey, scope.userID] + arguments)
                ))

                result.playlistIDs.formUnion(try String.fetchAll(
                    db,
                    sql: """
                        SELECT DISTINCT playlistID FROM playlistEntry
                        WHERE serverKey = ? AND userID = ? AND itemID IN (\(slots))
                        """,
                    arguments: StatementArguments([scope.serverKey, scope.userID] + arguments)
                ))
            }

            // An album counts for its own album artist too, otherwise a
            // compilation's artist looks empty when every track on it is
            // credited to somebody else. Both sources are needed: `itemArtist`
            // carries a track's several credits, while the album artist is only
            // ever written to `libraryItem`.
            try Self.forEachIDBatch(trackIDs.union(result.albumIDs)) { slots, arguments in
                let scoped = StatementArguments([scope.serverKey, scope.userID] + arguments)
                result.artistIDs.formUnion(try String.fetchAll(
                    db,
                    sql: """
                        SELECT DISTINCT artistID FROM itemArtist
                        WHERE serverKey = ? AND userID = ? AND itemID IN (\(slots))
                        """,
                    arguments: scoped
                ))
                result.artistIDs.formUnion(try String.fetchAll(
                    db,
                    sql: """
                        SELECT DISTINCT artistID FROM libraryItem
                        WHERE serverKey = ? AND userID = ?
                          AND artistID IS NOT NULL AND itemID IN (\(slots))
                        """,
                    arguments: scoped
                ))
            }
            return result
        }
    }

    /// SQLite caps how many variables one statement may bind, and a large
    /// download set would sail past it in a single `IN (…)`.
    private static func forEachIDBatch(
        _ ids: Set<String>,
        batchSize: Int = 400,
        body: (String, [String]) throws -> Void
    ) rethrows {
        let all = Array(ids)
        var start = all.startIndex
        while start < all.endIndex {
            let end = min(start + batchSize, all.endIndex)
            let batch = Array(all[start..<end])
            try body(databaseQuestionMarks(count: batch.count), batch)
            start = end
        }
    }

    /// Records which artists the server calls album artists. Browsing lists
    /// only these; everything else stays in the catalog so a track credited to
    /// a guest can still be searched for and navigated to.
    func replaceAlbumArtists(_ artistIDs: Set<String>, in scope: LibraryScope) throws {
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM albumArtist WHERE serverKey = ? AND userID = ?",
                arguments: [scope.serverKey, scope.userID]
            )
            for artistID in artistIDs {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO albumArtist (serverKey, userID, artistID)
                        VALUES (?, ?, ?)
                        """,
                    arguments: [scope.serverKey, scope.userID, artistID]
                )
            }
        }
    }

    /// Nothing recorded means nothing has synced since this became a feature,
    /// and an unfiltered list beats an empty one.
    private static func hasAlbumArtists(_ db: Database, scope: LibraryScope) throws -> Bool {
        try Int.fetchOne(
            db,
            sql: "SELECT 1 FROM albumArtist WHERE serverKey = ? AND userID = ? LIMIT 1",
            arguments: [scope.serverKey, scope.userID]
        ) != nil
    }

    private static func browsableArtists(
        _ db: Database,
        scope: LibraryScope
    ) throws -> [LibraryItemRecord] {
        guard try hasAlbumArtists(db, scope: scope) else {
            return try items(db, scope: scope, type: .artist)
        }
        return try LibraryItemRecord.fetchAll(
            db,
            sql: """
                SELECT item.* FROM libraryItem AS item
                JOIN albumArtist AS marker
                  ON marker.serverKey = item.serverKey
                 AND marker.userID = item.userID
                 AND marker.artistID = item.itemID
                WHERE item.serverKey = ? AND item.userID = ? AND item.itemType = ?
                ORDER BY item.sortName COLLATE NOCASE
                """,
            arguments: [scope.serverKey, scope.userID, LibraryItemType.artist.rawValue]
        )
    }

    /// Links items to artists the way the server does, for the items whose
    /// payload arrived without the link.
    ///
    /// Jellyfin resolves an item's artist IDs at serialisation time with an
    /// exact-name dictionary lookup and silently drops what it cannot match —
    /// so an album tagged `:wumpscut:` under an artist named `:Wumpscut:`
    /// arrives with `AlbumArtists: []`. Its *queries* match on a normalised
    /// name instead, which is why the same server will happily list those
    /// albums when asked by that artist's ID. This applies the same
    /// normalisation, so the local catalog answers the way the server does.
    @discardableResult
    func linkArtistsByName(in scope: LibraryScope) throws -> Int {
        try database.write { db in
            let artists = try Row.fetchAll(
                db,
                sql: """
                    SELECT itemID, name FROM libraryItem
                    WHERE serverKey = ? AND userID = ? AND itemType = ?
                    """,
                arguments: [scope.serverKey, scope.userID, LibraryItemType.artist.rawValue]
            )

            // First writer wins, matching the server taking `albumArtists[0]`.
            var byCleanName: [String: String] = [:]
            for row in artists {
                let name: String = row["name"]
                let id: String = row["itemID"]
                let key = Self.cleanName(name)
                guard !key.isEmpty, byCleanName[key] == nil else { continue }
                byCleanName[key] = id
            }
            guard !byCleanName.isEmpty else { return 0 }

            let unlinked = try Row.fetchAll(
                db,
                sql: """
                    SELECT item.itemID, item.artistName FROM libraryItem AS item
                    LEFT JOIN itemArtist AS relation
                      ON relation.serverKey = item.serverKey
                     AND relation.userID = item.userID
                     AND relation.itemID = item.itemID
                    WHERE item.serverKey = ? AND item.userID = ?
                      AND item.itemType IN (?, ?)
                      AND item.artistName IS NOT NULL
                      AND item.artistID IS NULL
                      AND relation.itemID IS NULL
                    """,
                arguments: [
                    scope.serverKey, scope.userID,
                    LibraryItemType.album.rawValue, LibraryItemType.track.rawValue
                ]
            )

            var linked = 0
            for row in unlinked {
                let artistName: String = row["artistName"]
                guard let artistID = byCleanName[Self.cleanName(artistName)] else { continue }
                let itemID: String = row["itemID"]
                try Self.saveArtistLink(
                    itemID: itemID,
                    artistID: artistID,
                    position: 0,
                    db: db,
                    scope: scope
                )
                // The artist page reads this column first, so it is filled in
                // too rather than left contradicting the relation row.
                try db.execute(
                    sql: """
                        UPDATE libraryItem SET artistID = ?
                        WHERE serverKey = ? AND userID = ? AND itemID = ?
                        """,
                    arguments: [artistID, scope.serverKey, scope.userID, itemID]
                )
                linked += 1
            }
            return linked
        }
    }

    /// Jellyfin's `GetCleanValue`: diacritics removed, lowercased.
    nonisolated static func cleanName(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated func tracks(inAlbum albumID: String, in scope: LibraryScope) async throws -> [Track] {
        try await readTracks(
            sql: """
                SELECT item.* FROM libraryItem AS item
                WHERE item.serverKey = ? AND item.userID = ?
                  AND item.itemType = ? AND item.albumID = ?
                ORDER BY COALESCE(item.parentIndexNumber, 0),
                         COALESCE(item.indexNumber, 0), item.sortName COLLATE NOCASE
                """,
            arguments: [scope.serverKey, scope.userID, LibraryItemType.track.rawValue, albumID],
            scope: scope
        )
    }

    nonisolated func tracks(forArtist artistID: String, in scope: LibraryScope) async throws -> [Track] {
        try await readTracks(
            sql: """
                SELECT item.* FROM libraryItem AS item
                JOIN itemArtist AS relation
                  ON relation.serverKey = item.serverKey
                 AND relation.userID = item.userID
                 AND relation.itemID = item.itemID
                WHERE item.serverKey = ? AND item.userID = ?
                  AND item.itemType = ? AND relation.artistID = ?
                ORDER BY item.albumName COLLATE NOCASE,
                         COALESCE(item.parentIndexNumber, 0),
                         COALESCE(item.indexNumber, 0), item.sortName COLLATE NOCASE
                """,
            arguments: [scope.serverKey, scope.userID, LibraryItemType.track.rawValue, artistID],
            scope: scope
        )
    }

    nonisolated func albums(forArtist artistID: String, in scope: LibraryScope) async throws -> [Album] {
        let database = database
        return try await Task.detached(priority: .userInitiated) {
            try database.read { db in
                let favorites = try Self.favoriteItemIDs(db, scope: scope)
                return try LibraryItemRecord.fetchAll(
                    db,
                    sql: """
                        SELECT DISTINCT item.* FROM libraryItem AS item
                        LEFT JOIN itemArtist AS relation
                          ON relation.serverKey = item.serverKey
                         AND relation.userID = item.userID
                         AND relation.itemID = item.itemID
                        WHERE item.serverKey = ? AND item.userID = ?
                          AND item.itemType = ?
                          AND (relation.artistID = ? OR item.artistID = ?)
                        ORDER BY item.sortName COLLATE NOCASE
                        """,
                    arguments: [
                        scope.serverKey, scope.userID, LibraryItemType.album.rawValue,
                        artistID, artistID
                    ]
                ).map { $0.album(isFavorite: favorites.contains($0.itemID)) }
            }
        }.value
    }

    func albums(inGenre genreID: String, in scope: LibraryScope) throws -> [Album] {
        try database.read { db in
            let favorites = try Self.favoriteItemIDs(db, scope: scope)
            return try LibraryItemRecord.fetchAll(
                db,
                sql: """
                    SELECT item.* FROM libraryItem AS item
                    JOIN itemGenre AS relation
                      ON relation.serverKey = item.serverKey
                     AND relation.userID = item.userID
                     AND relation.itemID = item.itemID
                    WHERE item.serverKey = ? AND item.userID = ?
                      AND item.itemType = ? AND relation.genreID = ?
                    ORDER BY item.sortName COLLATE NOCASE
                    """,
                arguments: [scope.serverKey, scope.userID, LibraryItemType.album.rawValue, genreID]
            ).map { $0.album(isFavorite: favorites.contains($0.itemID)) }
        }
    }

    nonisolated func tracks(inPlaylist playlistID: String, in scope: LibraryScope) async throws -> [Track] {
        try await readTracks(
            sql: """
                SELECT item.* FROM playlistEntry AS entry
                JOIN libraryItem AS item
                  ON item.serverKey = entry.serverKey
                 AND item.userID = entry.userID
                 AND item.itemID = entry.itemID
                WHERE entry.serverKey = ? AND entry.userID = ? AND entry.playlistID = ?
                ORDER BY entry.position
                """,
            arguments: [scope.serverKey, scope.userID, playlistID],
            scope: scope
        )
    }

    func search(
        _ query: String,
        filter: LibrarySearchFilter,
        in scope: LibraryScope,
        limit: Int = 100
    ) throws -> [LibrarySearchResult] {
        let tokens = query
            .split(whereSeparator: { $0.isWhitespace })
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }
        guard !tokens.isEmpty else { return [] }

        let allowedTypes: [LibraryItemType]
        switch filter {
        case .all: allowedTypes = [.artist, .album, .track, .playlist]
        case .artists: allowedTypes = [.artist]
        case .albums: allowedTypes = [.album]
        case .tracks: allowedTypes = [.track]
        case .playlists: allowedTypes = [.playlist]
        }
        let placeholders = allowedTypes.map { _ in "?" }.joined(separator: ",")
        var arguments: StatementArguments = [tokens.joined(separator: " AND "), scope.serverKey, scope.userID]
        for type in allowedTypes { arguments += [type.rawValue] }
        arguments += [limit]

        return try database.read { db in
            let favorites = try Self.favoriteItemIDs(db, scope: scope)
            // Searching turns up album artists only, for the same reason the
            // library list does: `feat.` and `vs.` credit strings are artist
            // entities on the server and would swamp the results. They stay in
            // the catalog, so navigating to one from a track still works.
            let artistRestriction = try Self.hasAlbumArtists(db, scope: scope)
                ? """
                  AND (item.itemType <> '\(LibraryItemType.artist.rawValue)'
                       OR EXISTS (
                           SELECT 1 FROM albumArtist AS marker
                           WHERE marker.serverKey = item.serverKey
                             AND marker.userID = item.userID
                             AND marker.artistID = item.itemID
                       ))
                  """
                : ""
            let records = try LibraryItemRecord.fetchAll(
                db,
                sql: """
                    SELECT item.*
                    FROM libraryItemFTS
                    JOIN libraryItem AS item
                      ON item.serverKey = libraryItemFTS.serverKey
                     AND item.userID = libraryItemFTS.userID
                     AND item.itemID = libraryItemFTS.itemID
                    WHERE libraryItemFTS MATCH ?
                      AND item.serverKey = ? AND item.userID = ?
                      AND item.itemType IN (\(placeholders))
                      \(artistRestriction)
                    ORDER BY bm25(libraryItemFTS, 7.0, 5.0, 3.0, 2.0),
                             item.sortName COLLATE NOCASE
                    LIMIT ?
                    """,
                arguments: arguments
            )
            return records.compactMap { record in
                let favorite = favorites.contains(record.itemID)
                switch record.itemType {
                case LibraryItemType.artist.rawValue: return .artist(record.artist(isFavorite: favorite))
                case LibraryItemType.album.rawValue: return .album(record.album(isFavorite: favorite))
                case LibraryItemType.track.rawValue: return .track(record.track(isFavorite: favorite))
                case LibraryItemType.playlist.rawValue: return .playlist(record.playlist(isFavorite: favorite))
                default: return nil
                }
            }
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
                // Playback updates recency, not the server-owned favorite flag.
                // Persisting the Track through `save(track:)` would copy the
                // usually-stale value carried by the playback queue over a
                // newer favorite state already stored in SQLite.
                try LibraryItemRecord(track: track, scope: scope).save(db)
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

    // MARK: - Discovery snapshot

    func discoverySnapshot(in scope: LibraryScope) -> DiscoverySnapshot? {
        do {
            return try database.read { db in
                guard let data = try Data.fetchOne(
                    db,
                    sql: """
                        SELECT payload FROM discoverySnapshot
                        WHERE serverKey = ? AND userID = ?
                        """,
                    arguments: [scope.serverKey, scope.userID]
                ) else { return nil }
                return try JSONDecoder().decode(DiscoverySnapshot.self, from: data)
            }
        } catch {
            logger.error("Unable to load Discover snapshot: \(error.localizedDescription)")
            return nil
        }
    }

    func saveDiscoverySnapshot(_ snapshot: DiscoverySnapshot, in scope: LibraryScope) {
        do {
            let payload = try JSONEncoder().encode(snapshot)
            try database.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO discoverySnapshot (serverKey, userID, payload, refreshedAt)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(serverKey, userID) DO UPDATE SET
                            payload = excluded.payload,
                            refreshedAt = excluded.refreshedAt
                        """,
                    arguments: [scope.serverKey, scope.userID, payload, snapshot.refreshedAt]
                )
            }
        } catch {
            logger.error("Unable to save Discover snapshot: \(error.localizedDescription)")
        }
    }

    func discoveryCandidates(in scope: LibraryScope) -> [DiscoveryCandidate] {
        do {
            return try database.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT item.*, state.lastPlayedAt, state.playCount, state.isFavorite,
                               GROUP_CONCAT(DISTINCT genre.genreID) AS discoveryGenreIDs
                        FROM libraryItem AS item
                        LEFT JOIN userItemState AS state
                          ON state.serverKey = item.serverKey
                         AND state.userID = item.userID
                         AND state.itemID = item.itemID
                        LEFT JOIN itemGenre AS genre
                          ON genre.serverKey = item.serverKey
                         AND genre.userID = item.userID
                         AND genre.itemID = item.itemID
                        WHERE item.serverKey = ?
                          AND item.userID = ?
                          AND item.itemType = ?
                        GROUP BY item.serverKey, item.userID, item.itemID
                        """,
                    arguments: [scope.serverKey, scope.userID, LibraryItemType.track.rawValue]
                )
                return try rows.map { row in
                    let record = try LibraryItemRecord(row: row)
                    let isFavorite = (row["isFavorite"] as Bool?) ?? false
                    let genreIDs = (row["discoveryGenreIDs"] as String?)?
                        .split(separator: ",")
                        .map(String.init)
                    return DiscoveryCandidate(
                        track: record.track(isFavorite: isFavorite, genreIDs: genreIDs),
                        lastPlayedAt: row["lastPlayedAt"],
                        playCount: (row["playCount"] as Int?) ?? 0,
                        isFavorite: isFavorite
                    )
                }
            }
        } catch {
            logger.error("Unable to load discovery candidates: \(error.localizedDescription)")
            return []
        }
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
            .appendingPathComponent("Aurelia", isDirectory: true)
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
        migrator.registerMigration("expandCompleteLibraryCatalog") { db in
            try db.alter(table: "libraryItem") { table in
                table.add(column: "sortName", .text)
                table.add(column: "parentID", .text)
                table.add(column: "imageTag", .text)
                table.add(column: "albumImageTag", .text)
            }

            try db.execute(sql: "UPDATE libraryItem SET sortName = name WHERE sortName IS NULL")
            try db.execute(sql: """
                CREATE INDEX libraryItem_type_sortName
                ON libraryItem(serverKey, userID, itemType, sortName COLLATE NOCASE, itemID)
                """)

            try db.create(table: "itemArtist") { table in
                table.column("serverKey", .text).notNull()
                table.column("userID", .text).notNull()
                table.column("itemID", .text).notNull()
                table.column("artistID", .text).notNull()
                table.column("position", .integer).notNull().defaults(to: 0)
                table.primaryKey(["serverKey", "userID", "itemID", "artistID"])
            }
            try db.execute(sql: """
                CREATE INDEX itemArtist_artist
                ON itemArtist(serverKey, userID, artistID, position, itemID)
                """)

            try db.create(table: "itemGenre") { table in
                table.column("serverKey", .text).notNull()
                table.column("userID", .text).notNull()
                table.column("itemID", .text).notNull()
                table.column("genreID", .text).notNull()
                table.primaryKey(["serverKey", "userID", "itemID", "genreID"])
            }
            try db.execute(sql: """
                CREATE INDEX itemGenre_genre
                ON itemGenre(serverKey, userID, genreID, itemID)
                """)

            try db.create(table: "playlistEntry") { table in
                table.column("serverKey", .text).notNull()
                table.column("userID", .text).notNull()
                table.column("playlistID", .text).notNull()
                table.column("itemID", .text).notNull()
                table.column("entryID", .text)
                table.column("position", .integer).notNull()
                table.primaryKey(["serverKey", "userID", "playlistID", "itemID"])
            }
            try db.execute(sql: """
                CREATE INDEX playlistEntry_position
                ON playlistEntry(serverKey, userID, playlistID, position)
                """)

            try db.execute(sql: """
                CREATE VIRTUAL TABLE libraryItemFTS USING fts5(
                    serverKey UNINDEXED,
                    userID UNINDEXED,
                    itemID UNINDEXED,
                    itemType UNINDEXED,
                    name,
                    sortName,
                    artistName,
                    albumName,
                    tokenize = 'unicode61 remove_diacritics 2'
                )
                """)
            try db.execute(sql: """
                INSERT INTO libraryItemFTS (
                    serverKey, userID, itemID, itemType,
                    name, sortName, artistName, albumName
                )
                SELECT serverKey, userID, itemID, itemType,
                       name, COALESCE(sortName, name), artistName, albumName
                FROM libraryItem
                """)
        }
        migrator.registerMigration("persistDiscoverySnapshot") { db in
            try db.create(table: "discoverySnapshot") { table in
                table.column("serverKey", .text).notNull()
                table.column("userID", .text).notNull()
                table.column("payload", .blob).notNull()
                table.column("refreshedAt", .datetime).notNull()
                table.primaryKey(["serverKey", "userID"])
            }
        }
        migrator.registerMigration("supportIncrementalLibrarySync") { db in
            try db.alter(table: "librarySyncState") { table in
                table.add(column: "metadataWatermark", .datetime)
                table.add(column: "userDataWatermark", .datetime)
                table.add(column: "lastReconciledAt", .datetime)
                table.add(column: "catalogRevision", .integer).notNull().defaults(to: 0)
            }
        }
        migrator.registerMigration("markAlbumArtists") { db in
            // A table of its own rather than a column: the item records are
            // persisted wholesale on every sync, which would reset a flag they
            // do not carry.
            try db.create(table: "albumArtist") { table in
                table.column("serverKey", .text).notNull()
                table.column("userID", .text).notNull()
                table.column("artistID", .text).notNull()
                table.primaryKey(["serverKey", "userID", "artistID"])
            }
        }

        migrator.registerMigration("resumableFullSync") { db in
            try db.create(table: "librarySyncProgress") { table in
                table.column("serverKey", .text).notNull()
                table.column("userID", .text).notNull()
                table.column("stage", .text).notNull()
                table.column("nextOffset", .integer).notNull()
                table.column("detail", .text)
                table.column("startedAt", .datetime).notNull()
                table.primaryKey(["serverKey", "userID"])
            }
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
                ORDER BY COALESCE(sortName, name) COLLATE NOCASE, itemID
                """,
            arguments: [scope.serverKey, scope.userID, type.rawValue]
        )
    }

    nonisolated private func readTracks(
        sql: String,
        arguments: StatementArguments,
        scope: LibraryScope
    ) async throws -> [Track] {
        let database = database
        return try await Task.detached(priority: .userInitiated) {
            try database.read { db in
                let favorites = try Self.favoriteItemIDs(db, scope: scope)
                return try LibraryItemRecord.fetchAll(db, sql: sql, arguments: arguments)
                    .map { $0.track(isFavorite: favorites.contains($0.itemID)) }
            }
        }.value
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

    private static func itemIDs(
        _ db: Database,
        scope: LibraryScope,
        type: LibraryItemType
    ) throws -> Set<String> {
        Set(try String.fetchAll(
            db,
            sql: """
                SELECT itemID FROM libraryItem
                WHERE serverKey = ? AND userID = ? AND itemType = ?
                """,
            arguments: [scope.serverKey, scope.userID, type.rawValue]
        ))
    }

    private static func deleteItem(
        _ itemID: String,
        db: Database,
        scope: LibraryScope
    ) throws {
        let arguments: StatementArguments = [scope.serverKey, scope.userID, itemID]
        try db.execute(
            sql: "DELETE FROM itemArtist WHERE serverKey = ? AND userID = ? AND (itemID = ? OR artistID = ?)",
            arguments: [scope.serverKey, scope.userID, itemID, itemID]
        )
        try db.execute(
            sql: "DELETE FROM itemGenre WHERE serverKey = ? AND userID = ? AND (itemID = ? OR genreID = ?)",
            arguments: [scope.serverKey, scope.userID, itemID, itemID]
        )
        try db.execute(
            sql: "DELETE FROM playlistEntry WHERE serverKey = ? AND userID = ? AND (playlistID = ? OR itemID = ?)",
            arguments: [scope.serverKey, scope.userID, itemID, itemID]
        )
        try db.execute(
            sql: "DELETE FROM libraryItemFTS WHERE serverKey = ? AND userID = ? AND itemID = ?",
            arguments: arguments
        )
        try db.execute(
            sql: "DELETE FROM libraryItem WHERE serverKey = ? AND userID = ? AND itemID = ?",
            arguments: arguments
        )
        try db.execute(
            sql: "DELETE FROM userItemState WHERE serverKey = ? AND userID = ? AND itemID = ?",
            arguments: arguments
        )
    }

    private static func replaceRelations(
        for album: Album,
        db: Database,
        scope: LibraryScope
    ) throws {
        try clearRelations(itemID: album.id, db: db, scope: scope)
        if let artistID = album.artistId {
            try saveArtistLink(itemID: album.id, artistID: artistID, position: 0, db: db, scope: scope)
        }
        for genreID in album.genreIDs ?? [] {
            try saveGenreLink(itemID: album.id, genreID: genreID, db: db, scope: scope)
        }
    }

    private static func replaceRelations(
        for track: Track,
        db: Database,
        scope: LibraryScope
    ) throws {
        try clearRelations(itemID: track.id, db: db, scope: scope)
        let artistIDs = track.artistIDs ?? track.artistId.map { [$0] } ?? []
        for (position, artistID) in artistIDs.enumerated() {
            try saveArtistLink(itemID: track.id, artistID: artistID, position: position, db: db, scope: scope)
        }
        for genreID in track.genreIDs ?? [] {
            try saveGenreLink(itemID: track.id, genreID: genreID, db: db, scope: scope)
        }
    }

    private static func clearRelations(
        itemID: String,
        db: Database,
        scope: LibraryScope
    ) throws {
        try db.execute(
            sql: "DELETE FROM itemArtist WHERE serverKey = ? AND userID = ? AND itemID = ?",
            arguments: [scope.serverKey, scope.userID, itemID]
        )
        try db.execute(
            sql: "DELETE FROM itemGenre WHERE serverKey = ? AND userID = ? AND itemID = ?",
            arguments: [scope.serverKey, scope.userID, itemID]
        )
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

    private static func save(tracks: [Track], db: Database, scope: LibraryScope) throws {
        for track in tracks { try save(track: track, db: db, scope: scope) }
    }

    private static func save(genres: [Genre], db: Database, scope: LibraryScope) throws {
        for genre in genres { try save(genre: genre, db: db, scope: scope) }
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
        try updateUserState(db, scope: scope, itemID: track.id, isFavorite: track.isFavorite)
    }

    private static func save(genre: Genre, db: Database, scope: LibraryScope) throws {
        try LibraryItemRecord(genre: genre, scope: scope).save(db)
    }

    private static func saveArtistLink(
        itemID: String,
        artistID: String,
        position: Int,
        db: Database,
        scope: LibraryScope
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO itemArtist (serverKey, userID, itemID, artistID, position)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(serverKey, userID, itemID, artistID) DO UPDATE SET
                    position = excluded.position
                """,
            arguments: [scope.serverKey, scope.userID, itemID, artistID, position]
        )
    }

    private static func saveGenreLink(
        itemID: String,
        genreID: String,
        db: Database,
        scope: LibraryScope
    ) throws {
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO itemGenre (serverKey, userID, itemID, genreID)
                VALUES (?, ?, ?, ?)
                """,
            arguments: [scope.serverKey, scope.userID, itemID, genreID]
        )
    }

    private static func rebuildSearchIndex(_ db: Database, scope: LibraryScope) throws {
        try db.execute(
            sql: "DELETE FROM libraryItemFTS WHERE serverKey = ? AND userID = ?",
            arguments: [scope.serverKey, scope.userID]
        )
        try db.execute(
            sql: """
                INSERT INTO libraryItemFTS (
                    serverKey, userID, itemID, itemType,
                    name, sortName, artistName, albumName
                )
                SELECT serverKey, userID, itemID, itemType,
                       name, COALESCE(sortName, name), artistName, albumName
                FROM libraryItem
                WHERE serverKey = ? AND userID = ?
                """,
            arguments: [scope.serverKey, scope.userID]
        )
    }

    private static func refreshSearchIndex(
        itemIDs: Set<String>,
        db: Database,
        scope: LibraryScope
    ) throws {
        for itemID in itemIDs {
            try db.execute(
                sql: "DELETE FROM libraryItemFTS WHERE serverKey = ? AND userID = ? AND itemID = ?",
                arguments: [scope.serverKey, scope.userID, itemID]
            )
            try db.execute(
                sql: """
                    INSERT INTO libraryItemFTS (
                        serverKey, userID, itemID, itemType,
                        name, sortName, artistName, albumName
                    )
                    SELECT serverKey, userID, itemID, itemType,
                           name, COALESCE(sortName, name), artistName, albumName
                    FROM libraryItem
                    WHERE serverKey = ? AND userID = ? AND itemID = ?
                    """,
                arguments: [scope.serverKey, scope.userID, itemID]
            )
        }
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
    case genre
}

nonisolated private struct LibraryItemRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "libraryItem"

    let serverKey: String
    let userID: String
    let itemID: String
    let itemType: String
    let name: String
    let sortName: String?
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
    let parentID: String?
    let imageTag: String?
    let albumImageTag: String?
    let updatedAt: Date

    init(track: Track, scope: LibraryScope) {
        serverKey = scope.serverKey
        userID = scope.userID
        itemID = track.id
        itemType = LibraryItemType.track.rawValue
        name = track.name
        sortName = track.sortName
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
        parentID = track.albumId
        imageTag = nil
        albumImageTag = nil
        updatedAt = Date()
    }

    init(album: Album, scope: LibraryScope) {
        serverKey = scope.serverKey
        userID = scope.userID
        itemID = album.id
        itemType = LibraryItemType.album.rawValue
        name = album.name
        sortName = album.sortName
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
        parentID = nil
        imageTag = nil
        albumImageTag = nil
        updatedAt = Date()
    }

    init(artist: Artist, scope: LibraryScope) {
        serverKey = scope.serverKey
        userID = scope.userID
        itemID = artist.id
        itemType = LibraryItemType.artist.rawValue
        name = artist.name
        sortName = artist.sortName
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
        parentID = nil
        imageTag = nil
        albumImageTag = nil
        updatedAt = Date()
    }

    init(playlist: Playlist, scope: LibraryScope) {
        serverKey = scope.serverKey
        userID = scope.userID
        itemID = playlist.id
        itemType = LibraryItemType.playlist.rawValue
        name = playlist.name
        sortName = playlist.sortName
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
        parentID = nil
        imageTag = nil
        albumImageTag = nil
        updatedAt = Date()
    }

    init(genre: Genre, scope: LibraryScope) {
        serverKey = scope.serverKey
        userID = scope.userID
        itemID = genre.id
        itemType = LibraryItemType.genre.rawValue
        name = genre.name
        sortName = genre.name
        artistName = nil
        artistID = nil
        albumName = nil
        albumID = nil
        productionYear = nil
        duration = nil
        artworkURL = nil
        indexNumber = nil
        parentIndexNumber = nil
        trackCount = genre.albumCount
        albumCount = nil
        biography = nil
        dateCreated = nil
        parentID = nil
        imageTag = nil
        albumImageTag = nil
        updatedAt = Date()
    }

    func track(isFavorite: Bool, genreIDs: [String]? = nil) -> Track {
        Track(
            id: itemID,
            name: name,
            sortName: sortName,
            artistName: artistName ?? "Unknown Artist",
            albumName: albumName ?? "Unknown Album",
            duration: duration ?? 0,
            artworkURL: artworkURL,
            isFavorite: isFavorite,
            indexNumber: indexNumber,
            parentIndexNumber: parentIndexNumber,
            albumId: albumID,
            artistId: artistID,
            artistIDs: artistID.map { [$0] },
            genreIDs: genreIDs,
            productionYear: productionYear
        )
    }

    func album(isFavorite: Bool) -> Album {
        Album(
            id: itemID,
            name: name,
            sortName: sortName,
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
            sortName: sortName,
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
            sortName: sortName,
            trackCount: trackCount ?? 0,
            artworkURL: artworkURL,
            dateCreated: dateCreated,
            isFavorite: isFavorite
        )
    }

    func genre() -> Genre {
        Genre(id: itemID, name: name, albumCount: trackCount)
    }
}
