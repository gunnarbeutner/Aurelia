import SwiftUI

struct ArtistContextMenu: View {
    let artist: Artist

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

            InstantMixButton(itemId: artist.id, itemName: artist.name)

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
        .tint(nil)
    }

    private func perform(_ action: Action) {
        Task {
            do {
                guard let scope = JellyfinService.shared.libraryScope else {
                    throw JellyfinError.notAuthenticated
                }
                let tracks = try await LibraryRepository.shared.tracks(forArtist: artist.id, in: scope)

                guard !tracks.isEmpty else {
                    playerManager.errorMessage = "This artist has no playable tracks."
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
                playerManager.errorMessage = "Unable to load \(artist.name): \(error.localizedDescription)"
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
