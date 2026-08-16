import Foundation

nonisolated enum AureliaSyncMode: String, Codable, Sendable {
    case snapshot
    case changes
}

nonisolated struct AureliaSyncStatus: Decodable, Sendable {
    let pluginVersion: String
    let protocolVersions: AureliaSyncVersionRange
    let wireSchemaVersions: AureliaSyncVersionRange
    let journal: AureliaSyncJournalStatus
    let snapshot: AureliaSyncSnapshotStatus
    let user: AureliaSyncUserStatus
    let enabled: Bool
    let health: String
    let healthDetail: String?

    var healthy: Bool { health == "ok" }

    /// Whether this build and this plugin have a protocol and wire schema
    /// version in common.
    var isCompatible: Bool {
        overlaps(protocolVersions, AureliaSyncClient.protocolRange)
            && overlaps(wireSchemaVersions, AureliaSyncClient.schemaRange)
    }

    /// Whether the plugin is the older of the two, and so the one to update.
    ///
    /// The mismatch runs both ways, and the answer decides who is asked to do
    /// something: an out-of-date server is a plugin to update, an out-of-date
    /// app is not something the server can fix.
    var isOlderThanClient: Bool {
        protocolVersions.max < AureliaSyncClient.protocolRange.lowerBound
            || wireSchemaVersions.max < AureliaSyncClient.schemaRange.lowerBound
    }

    private func overlaps(_ server: AureliaSyncVersionRange, _ client: ClosedRange<Int>) -> Bool {
        server.min <= client.upperBound && server.max >= client.lowerBound
    }
}

nonisolated struct AureliaSyncVersionRange: Decodable, Sendable { let min: Int; let max: Int }
nonisolated struct AureliaSyncJournalStatus: Decodable, Sendable { let head: Int64; let floor: Int64; let records: Int64 }
nonisolated struct AureliaSyncSnapshotStatus: Decodable, Sendable { let state: String; let generation: Int64?; let rowCount: Int64?; let phase: String? }
nonisolated struct AureliaSyncUserStatus: Decodable, Sendable { let id: String; let hasCheckpoint: Bool; let needsSnapshot: Bool }

nonisolated struct AureliaSyncOpenSessionRequest: Encodable, Sendable {
    let clientId: String
    let clientVersion: String
    let protocolMin: Int
    let protocolMax: Int
    let schemaMin: Int
    let schemaMax: Int
    let checkpointToken: String?
    let reset: Bool
}

nonisolated struct AureliaSyncSession: Decodable, Sendable {
    let sessionId: String
    let mode: AureliaSyncMode
    let protocolVersion: Int
    let schemaVersion: Int
    let cursor: String?
    let checkpointToken: String?
    let snapshotGeneration: String?
    let journalHead: Int64?
    let expiresAt: Date?
    let state: String?
    let message: String?
    let reason: String?
}

nonisolated struct AureliaSyncAcknowledgement: Codable, Equatable, Sendable {
    let throughCursor: String
    let clientCommitId: String
    let recordCount: Int
}

nonisolated struct AureliaSyncSegment: Sendable {
    let records: [AureliaSyncRecord]
    let cursor: String
    let caughtUp: Bool
}

nonisolated struct AureliaSyncRecord: Decodable, Sendable {
    let cursor: String
    let sequence: Int64?
    let kind: String
    let entityType: String?
    let entityId: String?
    let payload: AureliaSyncEntityPayload?
}

/// Version-one sync DTO. It is Aurelia-owned rather than a raw Jellyfin DTO so
/// the plugin can evolve independently of Jellyfin's public JSON shape.
nonisolated struct AureliaSyncEntityPayload: Decodable, Sendable {
    let id: String?
    let name: String?
    let sortName: String?
    let artistName: String?
    let artistId: String?
    let artistIDs: [String]?
    let albumId: String?
    let productionYear: Int?
    let duration: Double?
    let imageTag: String?
    let isAlbumArtist: Bool?
    let indexNumber: Int?
    let parentIndexNumber: Int?
    let biography: String?
    let dateCreated: Date?
    let genreIDs: [String]?
    let playlistEntryID: String?
    let playlistID: String?
    let position: Int?
    let isFavorite: Bool?
    let lastPlayedAt: Date?
    let playCount: Int?
    let playbackPositionTicks: Int64?

    /// A track names its album by identifier only; the album record owns the
    /// name and the artwork, and the store fills both in when a track is read.
    func track(fallbackID: String? = nil, baseURL: String) throws -> Track {
        guard let id = id ?? fallbackID, let name else { throw AureliaSyncError.invalidPayload }
        return Track(
            id: id, name: name, sortName: sortName,
            artistName: artistName ?? "Unknown Artist",
            albumName: "",
            duration: duration ?? 0, artworkURL: nil,
            isFavorite: isFavorite ?? false, indexNumber: indexNumber,
            parentIndexNumber: parentIndexNumber, albumId: albumId,
            artistId: artistId ?? artistIDs?.first, artistIDs: artistIDs,
            genreIDs: genreIDs, playlistEntryID: playlistEntryID,
            productionYear: productionYear
        )
    }

    func album(fallbackID: String? = nil, baseURL: String) throws -> Album {
        guard let id = id ?? fallbackID, let name else { throw AureliaSyncError.invalidPayload }
        return Album(
            id: id, name: name, sortName: sortName,
            artistName: artistName ?? "Unknown Artist", artistId: artistId,
            year: productionYear, trackCount: nil,
            artworkURL: Self.artworkURL(itemID: id, imageTag: imageTag, baseURL: baseURL),
            genreIDs: genreIDs, isFavorite: isFavorite ?? false
        )
    }

    func artist(fallbackID: String? = nil, baseURL: String) throws -> Artist {
        guard let id = id ?? fallbackID, let name else { throw AureliaSyncError.invalidPayload }
        return Artist(
            id: id, name: name, sortName: sortName, bio: biography,
            albumCount: 0,
            artworkURL: Self.artworkURL(itemID: id, imageTag: imageTag, baseURL: baseURL),
            isFavorite: isFavorite ?? false
        )
    }

    func playlist(fallbackID: String? = nil, baseURL: String) throws -> Playlist {
        guard let id = id ?? fallbackID, let name else { throw AureliaSyncError.invalidPayload }
        return Playlist(
            id: id, name: name, sortName: sortName,
            trackCount: 0,
            artworkURL: Self.artworkURL(itemID: id, imageTag: imageTag, baseURL: baseURL),
            dateCreated: dateCreated, isFavorite: isFavorite ?? false
        )
    }

    func genre(fallbackID: String? = nil) throws -> Genre {
        guard let id = id ?? fallbackID, let name else { throw AureliaSyncError.invalidPayload }
        return Genre(id: id, name: name, albumCount: nil)
    }

    private static func artworkURL(itemID: String, imageTag: String?, baseURL: String) -> String? {
        guard let imageTag, !imageTag.isEmpty else { return nil }
        let root = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "\(root)/Items/\(itemID)/Images/Primary?maxWidth=300&tag=\(imageTag)"
    }
}

nonisolated enum AureliaSyncError: LocalizedError, Sendable {
    case required
    case disabled(String?)
    case incompatible(String)
    case invalidResponse
    case invalidStream(String)
    case invalidPayload
    case rateLimited(retryAfter: Date?, message: String?)
    case http(Int, String?)
    case structured(code: String, message: String, correlationId: String?)

    var errorDescription: String? {
        switch self {
        case .required: return "Aurelia Sync is required. Install the Aurelia Sync plugin on this Jellyfin server and restart Jellyfin."
        case .disabled(let message): return message ?? "Aurelia Sync is disabled on this server."
        case .incompatible: return "Aurelia and the installed Aurelia Sync version cannot update your library together. Please update both and try again."
        case .invalidResponse: return "The server returned an unexpected response while updating your library. Please try again."
        case .invalidStream: return "The library update was incomplete or damaged. Your existing library was kept; please try again."
        case .invalidPayload: return "The library update contained an item Aurelia could not save. Your existing library was kept."
        case .rateLimited(let retryAfter, let message):
            let retryText: String
            if let retryAfter {
                retryText = " Try again \(retryAfter.formatted(.relative(presentation: .named)))."
            } else {
                retryText = " Please wait a few minutes and try again."
            }
            return (message ?? "The server is temporarily limiting library rebuilds.") + retryText
        case .http(let status, let message):
            return message.map { "The server could not update your library (error \(status)): \($0)" }
                ?? "The server could not update your library (error \(status))."
        case .structured(_, let message, let correlationId):
            return correlationId.map { "\(message) (reference \($0))" } ?? message
        }
    }
}

/// Incremental NDJSON decoder. It buffers at most one line plus the bounded
/// segment records and rejects a response unless a final `segment.end` arrives.
nonisolated enum AureliaSyncNDJSON {
    private struct Control: Decodable {
        let kind: String
        let cursor: String?
        let caughtUp: Bool?
        let code: String?
        let message: String?
        let correlationId: String?
    }

    static func decode<S: AsyncSequence>(bytes: S, maximumBytes: Int = 8 * 1024 * 1024) async throws -> AureliaSyncSegment where S.Element == UInt8 {
        let decoder = JSONDecoder.aureliaSync
        var records: [AureliaSyncRecord] = []
        var line = Data()
        var total = 0
        var began = false
        var end: Control?

        func consume(_ data: Data) throws {
            guard !data.isEmpty else { return }
            guard let control = try? decoder.decode(Control.self, from: data) else {
                throw AureliaSyncError.invalidStream("malformed NDJSON")
            }
            switch control.kind {
            case "segment.begin":
                guard !began, records.isEmpty else { throw AureliaSyncError.invalidStream("duplicate segment beginning") }
                began = true
            case "segment.end":
                guard began, end == nil else { throw AureliaSyncError.invalidStream("unexpected segment ending") }
                end = control
            case "error":
                throw AureliaSyncError.structured(
                    code: control.code ?? "streamError",
                    message: control.message ?? "The server stopped the sync stream.",
                    correlationId: control.correlationId
                )
            default:
                guard began, end == nil else { throw AureliaSyncError.invalidStream("record outside segment") }
                let record = try decoder.decode(AureliaSyncRecord.self, from: data)
                guard record.kind == control.kind else { throw AureliaSyncError.invalidStream("record kind mismatch") }
                records.append(record)
            }
        }

        for try await byte in bytes {
            total += 1
            guard total <= maximumBytes else { throw AureliaSyncError.invalidStream("segment exceeded its byte limit") }
            if byte == 0x0A {
                try consume(line)
                line.removeAll(keepingCapacity: true)
            } else if byte != 0x0D {
                line.append(byte)
            }
        }
        if !line.isEmpty {
            try consume(line)
        }
        guard began, let end, let cursor = end.cursor else {
            throw AureliaSyncError.invalidStream("missing segment.end")
        }
        return AureliaSyncSegment(
            records: records,
            cursor: cursor,
            caughtUp: end.caughtUp ?? false
        )
    }
}

extension JSONDecoder {
    nonisolated static var aureliaSync: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid ISO-8601 date"))
            }
            return date
        }
        return decoder
    }
}
