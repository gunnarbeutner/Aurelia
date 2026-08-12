//
//  LibraryEntities.swift
//  Aurelia
//
//  App Intents entities for albums, artists and playlists
//

import AppIntents
import Foundation

// MARK: - Album

struct AlbumEntity: AppEntity {
    let id: String
    let name: String
    let artistName: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Album" }
    static var defaultQuery = AlbumEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(artistName)")
    }

    init(_ album: Album) {
        id = album.id
        name = album.name
        artistName = album.artistName
    }
}

struct AlbumEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [AlbumEntity] {
        guard let snapshot = await AureliaActions.snapshot() else { return [] }
        let wanted = Set(identifiers)
        return snapshot.albums.filter { wanted.contains($0.id) }.map(AlbumEntity.init)
    }

    func entities(matching string: String) async throws -> [AlbumEntity] {
        await AureliaActions.searchCatalog(string, filter: .albums).compactMap {
            if case .album(let album) = $0 { return AlbumEntity(album) }
            return nil
        }
    }

    func suggestedEntities() async throws -> [AlbumEntity] {
        guard let snapshot = await AureliaActions.snapshot() else { return [] }
        return snapshot.albums.prefix(10).map(AlbumEntity.init)
    }
}

// MARK: - Artist

struct ArtistEntity: AppEntity {
    let id: String
    let name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Artist" }
    static var defaultQuery = ArtistEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    init(_ artist: Artist) {
        id = artist.id
        name = artist.name
    }
}

struct ArtistEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ArtistEntity] {
        guard let snapshot = await AureliaActions.snapshot() else { return [] }
        let wanted = Set(identifiers)
        return snapshot.artists.filter { wanted.contains($0.id) }.map(ArtistEntity.init)
    }

    func entities(matching string: String) async throws -> [ArtistEntity] {
        await AureliaActions.searchCatalog(string, filter: .artists).compactMap {
            if case .artist(let artist) = $0 { return ArtistEntity(artist) }
            return nil
        }
    }

    func suggestedEntities() async throws -> [ArtistEntity] {
        guard let snapshot = await AureliaActions.snapshot() else { return [] }
        return snapshot.artists.prefix(10).map(ArtistEntity.init)
    }
}

// MARK: - Playlist

struct PlaylistEntity: AppEntity {
    let id: String
    let name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Playlist" }
    static var defaultQuery = PlaylistEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    init(_ playlist: Playlist) {
        id = playlist.id
        name = playlist.name
    }
}

struct PlaylistEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [PlaylistEntity] {
        guard let snapshot = await AureliaActions.snapshot() else { return [] }
        let wanted = Set(identifiers)
        return snapshot.playlists.filter { wanted.contains($0.id) }.map(PlaylistEntity.init)
    }

    func entities(matching string: String) async throws -> [PlaylistEntity] {
        await AureliaActions.searchCatalog(string, filter: .playlists).compactMap {
            if case .playlist(let playlist) = $0 { return PlaylistEntity(playlist) }
            return nil
        }
    }

    func suggestedEntities() async throws -> [PlaylistEntity] {
        guard let snapshot = await AureliaActions.snapshot() else { return [] }
        return snapshot.playlists.prefix(10).map(PlaylistEntity.init)
    }
}
