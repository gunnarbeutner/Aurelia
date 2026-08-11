//
//  MockData.swift
//  Aurelia
//
//  Data models that bridge between Jellyfin API and UI
//

import Foundation

// MARK: - Track Model
nonisolated struct Track: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: String
    let name: String
    let sortName: String?
    let artistName: String
    let albumName: String
    let duration: TimeInterval
    let artworkURL: String?
    var isFavorite: Bool
    let indexNumber: Int?        // Track number
    let parentIndexNumber: Int?  // Disc number
    let albumId: String?         // For grouping tracks by album
    let artistId: String?        // For artist identification
    let artistIDs: [String]?
    let genreIDs: [String]?
    let playlistEntryID: String?
    let productionYear: Int?     // Album release year

    var durationFormatted: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    // Codable conformance - exclude computed properties
    enum CodingKeys: String, CodingKey {
        case id, name, sortName, artistName, albumName, duration, artworkURL, isFavorite, indexNumber, parentIndexNumber, albumId, artistId, artistIDs, genreIDs, playlistEntryID, productionYear
    }

    // Initialize from Jellyfin BaseItemDto
    init(from item: BaseItemDto, baseURL: String) {
        self.id = item.Id
        self.name = item.Name
        self.sortName = item.SortName
        self.artistName = item.artistName
        self.albumName = item.Album ?? "Unknown Album"
        self.duration = item.durationSeconds ?? 0
        self.artworkURL = item.albumArtworkURL(baseURL: baseURL)?.absoluteString
        self.isFavorite = item.UserData?.IsFavorite ?? false
        self.indexNumber = item.IndexNumber
        self.parentIndexNumber = item.ParentIndexNumber
        self.albumId = item.AlbumId
        self.artistId = item.ArtistItems?.first?.Id
        self.artistIDs = item.ArtistItems?.map(\.Id)
        self.genreIDs = item.GenreItems?.map(\.Id)
        self.playlistEntryID = item.PlaylistItemId
        self.productionYear = item.ProductionYear
    }

    // Manual initializer for mock data
    init(id: String, name: String, sortName: String? = nil, artistName: String, albumName: String, duration: TimeInterval, artworkURL: String?, isFavorite: Bool = false, indexNumber: Int? = nil, parentIndexNumber: Int? = nil, albumId: String? = nil, artistId: String? = nil, artistIDs: [String]? = nil, genreIDs: [String]? = nil, playlistEntryID: String? = nil, productionYear: Int? = nil) {
        self.id = id
        self.name = name
        self.sortName = sortName
        self.artistName = artistName
        self.albumName = albumName
        self.duration = duration
        self.artworkURL = artworkURL
        self.isFavorite = isFavorite
        self.indexNumber = indexNumber
        self.parentIndexNumber = parentIndexNumber
        self.albumId = albumId
        self.artistId = artistId
        self.artistIDs = artistIDs
        self.genreIDs = genreIDs
        self.playlistEntryID = playlistEntryID
        self.productionYear = productionYear
    }
}

// MARK: - Mock Data
extension Track {
    static let mockTrack1 = Track(
        id: "1",
        name: "Neon Dreams",
        artistName: "Cyber Synthwave",
        albumName: "Digital Horizons",
        duration: 245,
        artworkURL: nil
    )

    static let mockTrack2 = Track(
        id: "2",
        name: "Electric Pulse",
        artistName: "Neon Collective",
        albumName: "Future Retro",
        duration: 198,
        artworkURL: nil
    )

    static let mockTrack3 = Track(
        id: "3",
        name: "Crystal Rain",
        artistName: "Glitch Artists",
        albumName: "Digital Dreams",
        duration: 312,
        artworkURL: nil
    )

    static let mockPlaylist = [mockTrack1, mockTrack2, mockTrack3]
}

// MARK: - Album Model
nonisolated struct Album: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let sortName: String?
    let artistName: String
    let artistId: String?
    let year: Int?
    let trackCount: Int?
    let artworkURL: String?
    let genreIDs: [String]?
    var isFavorite: Bool

    // Initialize from Jellyfin BaseItemDto
    init(from item: BaseItemDto, baseURL: String) {
        self.id = item.Id
        self.name = item.Name
        self.sortName = item.SortName
        self.artistName = item.AlbumArtist ?? item.artistName
        self.artistId = item.AlbumArtists?.first?.Id ?? item.ArtistItems?.first?.Id
        self.year = item.ProductionYear
        self.trackCount = item.ChildCount
        self.artworkURL = item.albumArtworkURL(baseURL: baseURL)?.absoluteString
        self.genreIDs = item.GenreItems?.map(\.Id)
        self.isFavorite = item.UserData?.IsFavorite ?? false
    }

    // Manual initializer for mock data
    init(id: String, name: String, sortName: String? = nil, artistName: String, artistId: String?, year: Int?, trackCount: Int? = nil, artworkURL: String?, genreIDs: [String]? = nil, isFavorite: Bool = false) {
        self.id = id
        self.name = name
        self.sortName = sortName
        self.artistName = artistName
        self.artistId = artistId
        self.year = year
        self.trackCount = trackCount
        self.artworkURL = artworkURL
        self.genreIDs = genreIDs
        self.isFavorite = isFavorite
    }
}

extension Album {
    static let mockAlbums = [
        Album(id: "1", name: "Digital Horizons", artistName: "Cyber Synthwave", artistId: "artist1", year: 2024, artworkURL: nil),
        Album(id: "2", name: "Future Retro", artistName: "Neon Collective", artistId: "artist2", year: 2023, artworkURL: nil),
        Album(id: "3", name: "Digital Dreams", artistName: "Glitch Artists", artistId: "artist3", year: 2025, artworkURL: nil),
        Album(id: "4", name: "Neon Nights", artistName: "Synth Masters", artistId: "artist4", year: 2024, artworkURL: nil),
        Album(id: "5", name: "Electric Dreams", artistName: "Wave Riders", artistId: "artist5", year: 2023, artworkURL: nil),
        Album(id: "6", name: "Cyber City", artistName: "Digital Souls", artistId: "artist6", year: 2025, artworkURL: nil),
        Album(id: "7", name: "Terminal Velocity", artistName: "Cyber Synthwave", artistId: "artist1", year: 2023, artworkURL: nil),
        Album(id: "8", name: "Data Stream", artistName: "Cyber Synthwave", artistId: "artist1", year: 2022, artworkURL: nil)
    ]
}

// MARK: - Artist Model
nonisolated struct Artist: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let sortName: String?
    let bio: String?
    let albumCount: Int
    let artworkURL: String?
    var isFavorite: Bool

    // These will be fetched separately in views (not included in Codable)
    var albums: [Album] = []
    var topTracks: [Track] = []

    // Codable conformance - exclude albums and topTracks from encoding
    enum CodingKeys: String, CodingKey {
        case id, name, sortName, bio, albumCount, artworkURL, isFavorite
    }
    
    // Hashable conformance - exclude albums and topTracks from hashing
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(name)
        hasher.combine(sortName)
        hasher.combine(bio)
        hasher.combine(albumCount)
        hasher.combine(artworkURL)
        hasher.combine(isFavorite)
    }
    
    static func == (lhs: Artist, rhs: Artist) -> Bool {
        return lhs.id == rhs.id &&
               lhs.name == rhs.name &&
               lhs.sortName == rhs.sortName &&
               lhs.bio == rhs.bio &&
               lhs.albumCount == rhs.albumCount &&
               lhs.artworkURL == rhs.artworkURL &&
               lhs.isFavorite == rhs.isFavorite
    }

    // Initialize from Jellyfin BaseItemDto
    init(from item: BaseItemDto, baseURL: String) {
        self.id = item.Id
        self.name = item.Name
        self.sortName = item.SortName
        self.bio = item.Overview
        self.albumCount = item.AlbumCount ?? 0
        self.artworkURL = item.artistImageURL(baseURL: baseURL)?.absoluteString
        self.isFavorite = item.UserData?.IsFavorite ?? false
    }

    // Manual initializer for mock data
    init(id: String, name: String, sortName: String? = nil, bio: String?, albumCount: Int, artworkURL: String?, isFavorite: Bool = false, albums: [Album] = [], topTracks: [Track] = []) {
        self.id = id
        self.name = name
        self.sortName = sortName
        self.bio = bio
        self.albumCount = albumCount
        self.artworkURL = artworkURL
        self.isFavorite = isFavorite
        self.albums = albums
        self.topTracks = topTracks
    }
}

extension Artist {
    static let mockArtists = [
        Artist(id: "artist1", name: "Cyber Synthwave", bio: "Electronic music pioneer blending retro synth sounds with modern production. Known for atmospheric soundscapes and pulsing basslines.", albumCount: 3, artworkURL: nil),
        Artist(id: "artist2", name: "Neon Collective", bio: "Experimental electronic group pushing boundaries of synthwave and ambient music.", albumCount: 1, artworkURL: nil),
        Artist(id: "artist3", name: "Glitch Artists", bio: "Digital sound architects creating intricate layers of glitch and IDM.", albumCount: 1, artworkURL: nil),
        Artist(id: "artist4", name: "Synth Masters", bio: "Vintage synthesizer enthusiasts crafting nostalgic yet fresh electronic tracks.", albumCount: 1, artworkURL: nil),
        Artist(id: "artist5", name: "Wave Riders", bio: "Dreamwave specialists creating ethereal soundscapes perfect for late-night drives.", albumCount: 1, artworkURL: nil),
        Artist(id: "artist6", name: "Digital Souls", bio: "Cyberpunk-inspired electronic artists painting dystopian futures through sound.", albumCount: 1, artworkURL: nil)
    ]
}

// MARK: - Playlist Model
nonisolated struct Playlist: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let sortName: String?
    var trackCount: Int
    let artworkURL: String?
    let dateCreated: Date?
    var isFavorite: Bool

    // Initialize from Jellyfin BaseItemDto
    init(from item: BaseItemDto, baseURL: String) {
        self.id = item.Id
        self.name = item.Name
        self.sortName = item.SortName
        self.trackCount = item.ChildCount ?? 0
        self.artworkURL = item.albumArtworkURL(baseURL: baseURL)?.absoluteString

        // Parse ISO8601 date string to Date
        if let dateString = item.DateCreated {
            let formatter = ISO8601DateFormatter()
            self.dateCreated = formatter.date(from: dateString)
        } else {
            self.dateCreated = nil
        }

        self.isFavorite = item.UserData?.IsFavorite ?? false
    }

    // Manual initializer
    init(id: String, name: String, sortName: String? = nil, trackCount: Int, artworkURL: String?, dateCreated: Date?, isFavorite: Bool = false) {
        self.id = id
        self.name = name
        self.sortName = sortName
        self.trackCount = trackCount
        self.artworkURL = artworkURL
        self.dateCreated = dateCreated
        self.isFavorite = isFavorite
    }
}

// MARK: - Genre Model
nonisolated struct Genre: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let albumCount: Int?

    init(from item: BaseItemDto) {
        self.id = item.Id
        self.name = item.Name
        self.albumCount = item.ChildCount
    }

    init(id: String, name: String, albumCount: Int?) {
        self.id = id
        self.name = name
        self.albumCount = albumCount
    }
}
