import SwiftUI

struct LidarrRequestsView: View {
    @ObservedObject private var lidarr = LidarrService.shared

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            if lidarr.requests.isEmpty {
                ContentUnavailableView {
                    Label("No Music Requests", systemImage: "tray")
                } description: {
                    Text("Open Search, switch to Add Music, and request an album.")
                }
            } else {
                List(lidarr.requests) { request in
                    LidarrRequestRow(request: request)
                        .listRowBackground(Color.appMidBackground)
                }
                .scrollContentBackground(.hidden)
                .refreshable { await lidarr.refreshRequests() }
            }
        }
        .navigationTitle("Music Requests")
        .navigationDestination(for: Album.self) { album in
            AlbumDetailView(album: album)
        }
        .task {
            while !Task.isCancelled {
                await lidarr.refreshRequests()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

private struct LidarrRequestRow: View {
    let request: LidarrRequest
    @ObservedObject private var lidarr = LidarrService.shared
    @State private var isRetrying = false
    @State private var retryError: String?

    var body: some View {
        if let album = availableAlbum {
            NavigationLink(value: album) { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(request.title)
                        .font(.body.weight(.semibold))
                        .foregroundColor(.appText)
                    Text(request.artistName)
                        .font(.subheadline)
                        .foregroundColor(.appTextSecondary)
                }
                Spacer()
                Label(request.state.displayName, systemImage: request.state.icon)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(request.state == .failed ? .red : .appAccent)
            }

            if let progress = request.progress, request.state == .downloading {
                ProgressView(value: progress)
                    .tint(.appAccent)
                Text(progress.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption2)
                    .foregroundColor(.appTextSecondary)
            }

            if let error = request.errorMessage, request.state == .failed {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                retryButton
            } else if request.state == .waitingForJellyfin {
                Text("Lidarr has imported the album. Waiting for the next Jellyfin library scan.")
                    .font(.caption)
                    .foregroundColor(.appTextSecondary)
            }

            if let retryError {
                Text(retryError)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: request.state == .failed ? .contain : .combine)
    }

    private var retryButton: some View {
        HStack {
            Spacer()
            Button {
                Task { await retry() }
            } label: {
                if isRetrying {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.appAccentText)
                } else {
                    Label("Retry Album", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.appAccentText)
                }
            }
            .buttonStyle(AppProminentButtonStyle())
            .disabled(isRetrying)
            .accessibilityLabel("Retry adding \(request.title) album")
        }
    }

    @MainActor
    private func retry() async {
        guard !isRetrying else { return }
        isRetrying = true
        retryError = nil
        defer { isRetrying = false }
        do {
            try await lidarr.retry(request)
        } catch {
            retryError = error.localizedDescription
        }
    }

    private var availableAlbum: Album? {
        guard request.state == .available, let id = request.jellyfinItemId else { return nil }
        return Album(
            id: id,
            name: request.title,
            artistName: request.artistName,
            artistId: nil,
            year: nil,
            artworkURL: nil,
            providerIDs: ["MusicBrainzReleaseGroup": request.foreignAlbumId]
        )
    }
}
