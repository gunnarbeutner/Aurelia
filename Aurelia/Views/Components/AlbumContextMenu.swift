import SwiftUI

struct AlbumContextMenu: View {
    let album: Album
    /// Dropped when the menu is opened from that artist's own page, where it
    /// would only offer to take you where you already are.
    var offersGoToArtist = true

    private let playerManager = PlayerManager.shared

    var body: some View {
        Group {
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

            if offersGoToArtist {
                Divider()

                Button {
                    NavigationCoordinator.shared.navigateToArtist(for: album)
                } label: {
                    Label("Go to Artist", systemImage: "person.fill")
                }
            }
        }
        .tint(nil)
    }

    private func perform(_ action: Action) {
        Task {
            do {
                guard let scope = JellyfinService.shared.libraryScope else {
                    throw JellyfinError.notAuthenticated
                }
                let tracks = try await LibraryRepository.shared.tracks(inAlbum: album.id, in: scope)

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
    var offersInstantMix = true
    /// Dropped when the menu is opened from that album's own page.
    var offersGoToAlbum = true
    /// Position of this track in the playback queue, when the menu is opened
    /// from a row that is already queued. The queue actions then *move* the
    /// track instead of inserting a second copy, and "Add to Queue" is dropped
    /// because it would be a no-op.
    var queueIndex: Int? = nil
    /// Opened from the player itself. Queue placement is dropped entirely:
    /// this track is playing, so "Play Next" and its neighbours have nothing
    /// left to mean.
    var isNowPlaying = false

    @ObservedObject private var downloadManager = DownloadManager.shared
    @ObservedObject private var playerManager = PlayerManager.shared

    var body: some View {
        Group {
            if offersInstantMix {
                InstantMixButton(itemId: track.id, itemName: track.name)

                Divider()
            }

            if offersGoToAlbum {
                Button {
                    NavigationCoordinator.shared.navigateToAlbum(for: track)
                } label: {
                    Label("Go to Album", systemImage: "square.stack")
                }
            }

            Button {
                NavigationCoordinator.shared.navigateToArtist(for: track)
            } label: {
                Label("Go to Artist", systemImage: "person.fill")
            }

            Divider()

            if isNowPlaying {
                EmptyView()
            } else if let queueIndex {
                Button {
                    playerManager.moveInQueue(
                        from: queueIndex,
                        to: playerManager.currentIndex + 1
                    )
                } label: {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }

                Button {
                    playerManager.moveInQueue(
                        from: queueIndex,
                        to: playerManager.queue.count
                    )
                } label: {
                    Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward")
                }

                // Swipe-to-delete covers this on iOS but is a poor fit for a
                // pointer, so the menu carries it too.
                Button(role: .destructive) {
                    playerManager.removeFromQueue(at: queueIndex)
                } label: {
                    Label("Remove from Queue", systemImage: "minus.circle")
                }
            } else {
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
        .tint(nil)
    }
}
