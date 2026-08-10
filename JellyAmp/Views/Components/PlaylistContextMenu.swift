import SwiftUI

struct PlaylistContextMenu: View {
    let playlist: Playlist

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

        InstantMixButton(itemId: playlist.id, itemName: playlist.name)

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
    }

    private func perform(_ action: Action) {
        Task {
            do {
                let items = try await jellyfinService.fetchTracks(parentId: playlist.id)
                let tracks = items
                    .map { Track(from: $0, baseURL: jellyfinService.baseURL) }
                    .sorted { ($0.indexNumber ?? 0) < ($1.indexNumber ?? 0) }

                guard !tracks.isEmpty else {
                    playerManager.errorMessage = "This playlist contains no playable tracks."
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
                playerManager.errorMessage = "Unable to load \(playlist.name): \(error.localizedDescription)"
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
