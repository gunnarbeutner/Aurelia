//
//  NavigationCoordinator.swift
//  JellyAmp
//
//  Coordinates navigation between overlay views (NowPlaying) and the tab/navigation stack
//

import SwiftUI
import Combine

class NavigationCoordinator: ObservableObject {
    static let shared = NavigationCoordinator()

    private let jellyfinService = JellyfinService.shared

    /// Set this to navigate to an artist after dismissing NowPlaying
    @Published var pendingArtistNavigation: Artist?

    /// Set this to navigate to an album after dismissing NowPlaying
    @Published var pendingAlbumNavigation: Album?

    /// Changes whenever playback should present the full Now Playing view.
    @Published private(set) var nowPlayingPresentationRequest: UUID?

    func presentNowPlaying() {
        nowPlayingPresentationRequest = UUID()
    }

    // MARK: - Media Navigation

    /// Navigates to the album associated with a track. Track metadata from
    /// recommendations and search results does not always include AlbumId, so
    /// fall back to an exact-name search before giving up.
    func navigateToAlbum(for track: Track) {
        if let albumId = track.albumId, !albumId.isEmpty {
            pendingAlbumNavigation = Album(
                id: albumId,
                name: track.albumName,
                artistName: track.artistName,
                artistId: track.artistId,
                year: track.productionYear,
                artworkURL: track.artworkURL
            )
            return
        }

        resolveAlbum(named: track.albumName, artistName: track.artistName)
    }

    /// Navigates to the artist associated with a track. Instant Mix tracks can
    /// omit ArtistId, so resolve the artist by its exact display name when
    /// necessary.
    func navigateToArtist(for track: Track) {
        if let artistId = track.artistId, !artistId.isEmpty {
            pendingArtistNavigation = Artist(
                id: artistId,
                name: track.artistName,
                bio: nil,
                albumCount: 0,
                artworkURL: nil
            )
            return
        }

        resolveArtist(named: track.artistName)
    }

    /// Navigates to an album's artist, resolving albums whose metadata omitted
    /// ArtistId through the same exact-name lookup used for tracks.
    func navigateToArtist(for album: Album) {
        if let artistId = album.artistId, !artistId.isEmpty {
            pendingArtistNavigation = Artist(
                id: artistId,
                name: album.artistName,
                bio: nil,
                albumCount: 0,
                artworkURL: nil
            )
            return
        }

        resolveArtist(named: album.artistName)
    }

    private func resolveAlbum(named name: String, artistName: String) {
        Task { [weak self] in
            guard let self else { return }
            let items = try? await self.jellyfinService.searchMusic(query: name)
            let normalizedName = self.normalize(name)
            let normalizedArtist = self.normalize(artistName)
            let exactAlbums = items?.filter {
                $0.Type == .MusicAlbum && self.normalize($0.Name) == normalizedName
            } ?? []
            guard let item = exactAlbums.first(where: {
                self.normalize($0.AlbumArtist ?? $0.Artists?.first ?? "") == normalizedArtist
            }) ?? exactAlbums.first else { return }
            let album = Album(from: item, baseURL: self.jellyfinService.baseURL)
            await MainActor.run {
                self.pendingAlbumNavigation = album
            }
        }
    }

    private func resolveArtist(named name: String) {
        Task { [weak self] in
            guard let self else { return }
            guard let item = await self.findExactItem(named: name, type: .MusicArtist) else { return }
            let artist = Artist(from: item, baseURL: self.jellyfinService.baseURL)
            await MainActor.run {
                self.pendingArtistNavigation = artist
            }
        }
    }

    private func findExactItem(named name: String, type: ItemType) async -> BaseItemDto? {
        guard let items = try? await jellyfinService.searchMusic(query: name) else { return nil }
        let normalizedName = normalize(name)
        return items.first {
            $0.Type == type && normalize($0.Name) == normalizedName
        }
    }

    private func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
