//
//  JellyAmp_Watch_Watch_AppTests.swift
//  JellyAmp Watch Watch AppTests
//
//  Created by Grafton on 10/17/25.
//

import Testing
import Foundation
@testable import JellyAmp_Watch_Watch_App

struct JellyAmp_Watch_Watch_AppTests {

    @Test func watchCatalogPersistsCompleteScopedSnapshotAndRelationships() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("JellyAmp-Watch-Test-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let repository = try WatchLibraryRepository(databaseURL: databaseURL)
        let scope = try #require(WatchLibraryScope(baseURL: "https://music.example", userID: "user-a"))
        let artist = WatchArtist(id: "artist-1", name: "Artist")
        let album = WatchAlbum(
            id: "album-1",
            name: "Album",
            artist: artist.name,
            artistId: artist.id,
            year: 2026
        )
        let track = WatchTrack(
            id: "track-1",
            name: "Track",
            artist: artist.name,
            artistIds: [artist.id],
            album: album.name,
            albumId: album.id,
            duration: 123,
            indexNumber: 1,
            parentIndexNumber: 1,
            isFavorite: true
        )
        let snapshot = WatchLibraryTransferSnapshot(
            scope: scope,
            generatedAt: Date(timeIntervalSince1970: 1234),
            artists: [artist],
            albums: [album],
            tracks: [track]
        )

        try await repository.replace(with: snapshot)

        let stored = try #require(try await repository.snapshot(in: scope))
        #expect(stored.artists == [artist])
        #expect(stored.albums == [album])
        #expect(stored.tracks == [track])
        #expect(try await repository.albums(for: artist, in: scope) == [album])
        #expect(try await repository.tracks(for: artist, in: scope) == [track])
        #expect(try await repository.tracks(inAlbum: album.id, in: scope) == [track])

        let otherScope = try #require(WatchLibraryScope(baseURL: "https://music.example", userID: "user-b"))
        #expect(try await repository.snapshot(in: otherScope) == nil)
    }

}
