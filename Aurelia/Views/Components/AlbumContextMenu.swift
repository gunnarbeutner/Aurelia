import SwiftUI

struct AlbumContextMenu: View {
    let album: Album

    private let jellyfinService = JellyfinService.shared
    private let playerManager = PlayerManager.shared

    var body: some View {
        Button {
            perform(.play)
        } label: {
            Label("Play", systemImage: "play.fill")
        }

        Button {
            perform(.shuffle)
        } label: {
            Label("Shuffle", systemImage: "shuffle")
        }

        InstantMixButton(itemId: album.id, itemName: album.name)

        Divider()

        Button {
            perform(.playNext)
        } label: {
            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }

        Button {
            perform(.addToQueue)
        } label: {
            Label("Add to Queue", systemImage: "text.append")
        }

        Divider()

        Button {
            NavigationCoordinator.shared.navigateToArtist(for: album)
        } label: {
            Label("Go to Artist", systemImage: "person.fill")
        }
    }

    private func perform(_ action: Action) {
        Task {
            do {
                let items = try await jellyfinService.getAlbumTracks(albumId: album.id)
                let tracks = items
                    .map { Track(from: $0, baseURL: jellyfinService.baseURL) }
                    .sorted(by: trackOrder)

                guard !tracks.isEmpty else {
                    playerManager.errorMessage = "This album contains no playable tracks."
                    return
                }

                switch action {
                case .play:
                    playerManager.play(tracks: tracks)
                case .shuffle:
                    playerManager.play(tracks: tracks.shuffled())
                case .playNext:
                    playerManager.playNext(tracks: tracks)
                case .addToQueue:
                    playerManager.addToQueue(tracks: tracks)
                }
            } catch {
                playerManager.errorMessage = "Unable to load \(album.name): \(error.localizedDescription)"
            }
        }
    }

    private func trackOrder(_ lhs: Track, _ rhs: Track) -> Bool {
        let lhsDisc = lhs.parentIndexNumber ?? 0
        let rhsDisc = rhs.parentIndexNumber ?? 0
        if lhsDisc != rhsDisc {
            return lhsDisc < rhsDisc
        }
        return (lhs.indexNumber ?? 0) < (rhs.indexNumber ?? 0)
    }

    private enum Action {
        case play
        case shuffle
        case playNext
        case addToQueue
    }
}

/// Shared context menu for tracks. Keeping the menu in one place makes the
/// song actions (including album/artist navigation) consistent across album,
/// playlist, favorites, discovery, and search results.
struct TrackContextMenu: View {
    let track: Track
    var onAddToPlaylist: (() -> Void)? = nil

    @ObservedObject private var downloadManager = DownloadManager.shared
    @ObservedObject private var playerManager = PlayerManager.shared

    var body: some View {
        InstantMixButton(itemId: track.id, itemName: track.name)

        Divider()

        Button {
            NavigationCoordinator.shared.navigateToAlbum(for: track)
        } label: {
            Label("Go to Album", systemImage: "square.stack")
        }

        Button {
            NavigationCoordinator.shared.navigateToArtist(for: track)
        } label: {
            Label("Go to Artist", systemImage: "person.fill")
        }

        Divider()

        Button {
            playerManager.playNext(track: track)
        } label: {
            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }

        Button {
            playerManager.playLast(track: track)
        } label: {
            Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward")
        }

        Button {
            playerManager.addToQueue(track: track)
        } label: {
            Label("Add to Queue", systemImage: "text.append")
        }

        if downloadManager.isDownloaded(trackId: track.id) {
            Button(role: .destructive) {
                downloadManager.deleteDownload(trackId: track.id)
            } label: {
                Label("Delete Download", systemImage: "trash")
            }
        } else {
            Button {
                downloadManager.downloadTrack(track)
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
        }

        if let onAddToPlaylist {
            Button {
                onAddToPlaylist()
            } label: {
                Label("Add to Playlist", systemImage: "plus.circle")
            }
        }
    }
}
