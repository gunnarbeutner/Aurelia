//
//  AlbumDetailView.swift
//  Aurelia
//
//  Album detail page with track listing - iOS 26 Liquid Glass + Cypherpunk
//

import SwiftUI
import PhotosUI

struct AlbumDetailView: View {
    let album: Album
    @ObservedObject var jellyfinService = JellyfinService.shared
    @ObservedObject var playerManager = PlayerManager.shared
    @ObservedObject var downloadManager = DownloadManager.shared
    private let repository = LibraryRepository.shared
    @Environment(\.dismiss) var dismiss
    @State private var isFavorite: Bool
    @State private var albumTracks: [Track] = []
    @State private var isLoadingTracks = false
    @State private var hasLoadedTracks: Bool
    @State private var showAddToPlaylist = false
    @State private var selectedTrackIds: [String] = []

    // Artwork upload
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isUploadingArt = false
    @State private var uploadArtError: String?
    @State private var localArtworkData: Data?
    private let fetchesTracksOnAppear: Bool

    init(album: Album, initialTracks: [Track]? = nil) {
        self.album = album
        _isFavorite = State(initialValue: album.isFavorite)
        if let initialTracks {
            _albumTracks = State(initialValue: initialTracks)
            _isLoadingTracks = State(initialValue: false)
            _hasLoadedTracks = State(initialValue: true)
            fetchesTracksOnAppear = false
        } else {
            _hasLoadedTracks = State(initialValue: false)
            fetchesTracksOnAppear = true
        }
    }

    // Calculate download state for album
    private var albumDownloadState: DownloadState {
        guard !albumTracks.isEmpty else { return .notDownloaded }

        let downloadedCount = albumTracks.filter { downloadManager.isDownloaded(trackId: $0.id) }.count
        let totalCount = albumTracks.count

        if downloadedCount == totalCount {
            return .downloaded
        } else if downloadedCount > 0 {
            let progress = Double(downloadedCount) / Double(totalCount)
            return .downloading(progress: progress)
        } else {
            // Check if any are actively downloading
            for track in albumTracks {
                if case .downloading = downloadManager.downloadStates[track.id] {
                    return .downloading(progress: 0)
                }
            }
            return .notDownloaded
        }
    }

    var totalDuration: String {
        let total = albumTracks.reduce(0) { $0 + $1.duration }
        let minutes = Int(total) / 60
        return "\(minutes) min"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Main Content
            ZStack {
                // Background: blurred album art (like Now Playing / PWA)
                albumBackground
                
                ScrollView {
                    VStack(spacing: 0) {
                        // Album Hero Section (extends behind status bar)
                        albumHeroSection
                            .padding(.top, -60) // Pull up behind status bar

                        // Action Buttons
                        actionButtonsSection

                        // Album Info
                        albumInfoSection

                        // Track Listing
                        trackListingSection

                        // The mini player overlays detail content on both iOS and
                        // Catalyst, so preserve enough scroll extent for the last row.
                        Color.clear.frame(height: 100)
                    }
                }

                // Navigation handled by NavigationStack
            }

        }
        .ignoresSafeArea(.keyboard)
        .onAppear {
            guard fetchesTracksOnAppear, !hasLoadedTracks else { return }
            hasLoadedTracks = true
            Task {
                await fetchAlbumTracks()
            }
        }
        .sheet(isPresented: $showAddToPlaylist) {
            PlaylistSelectionSheet(trackIds: selectedTrackIds) {
                // Tracks added successfully
                selectedTrackIds = []
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(8)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .alert("Photo Upload", isPresented: Binding(get: { uploadArtError != nil }, set: { if !$0 { uploadArtError = nil } })) {
            Button("OK") { uploadArtError = nil }
        } message: {
            Text(uploadArtError ?? "")
        }
    }

    // MARK: - Fetch Album Tracks
    private func fetchAlbumTracks() async {
        await DelayedLoading.run { isLoadingTracks = $0 } work: {
            guard let scope = jellyfinService.libraryScope else { return }
            albumTracks = (try? await repository.tracks(inAlbum: album.id, in: scope)) ?? []
        }
    }

    // MARK: - Toggle Favorite
    private func toggleFavorite() {
        // Optimistic UI update
        withAnimation(.spring(response: 0.3)) {
            isFavorite.toggle()
        }
        let updatedFavoriteValue = isFavorite

        // Call API in background
        Task {
            do {
                if updatedFavoriteValue {
                    try await jellyfinService.markFavorite(itemId: album.id)
                } else {
                    try await jellyfinService.unmarkFavorite(itemId: album.id)
                }
                FavoriteMutationCenter.shared.publish(
                    .album(album, isFavorite: updatedFavoriteValue)
                )
            } catch {
                // Revert on failure
                await MainActor.run {
                    withAnimation(.spring(response: 0.3)) {
                        isFavorite.toggle()
                    }
                }
                print("Error toggling favorite: \(error)")
            }
        }
    }

    private func toggleFavorite(for trackID: String) {
        guard let index = albumTracks.firstIndex(where: { $0.id == trackID }) else { return }
        let originalTrack = albumTracks[index]
        let updatedFavoriteValue = !originalTrack.isFavorite

        withAnimation(.spring(response: 0.3)) {
            albumTracks[index].isFavorite = updatedFavoriteValue
        }

        Task {
            do {
                if updatedFavoriteValue {
                    try await jellyfinService.markFavorite(itemId: trackID)
                } else {
                    try await jellyfinService.unmarkFavorite(itemId: trackID)
                }
                FavoriteMutationCenter.shared.publish(
                    .track(originalTrack, isFavorite: updatedFavoriteValue)
                )
            } catch {
                guard let currentIndex = albumTracks.firstIndex(where: { $0.id == trackID }),
                      albumTracks[currentIndex].isFavorite == updatedFavoriteValue else { return }
                withAnimation(.spring(response: 0.3)) {
                    albumTracks[currentIndex].isFavorite = originalTrack.isFavorite
                }
            }
        }
    }

    // MARK: - Download Management

    /// True when the favorites rule is holding this album. Deleting it by hand
    /// would only start the download again, so the button stops offering to.
    private var isAlbumManagedByRule: Bool {
        !albumTracks.isEmpty && albumTracks.allSatisfy {
            downloadManager.isManagedByRule(trackId: $0.id)
        }
    }

    private func toggleDownload() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            if albumDownloadState.isDownloaded {
                // Delete all downloaded tracks
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.warning)

                for track in albumTracks {
                    // Drop this screen's claim only. A file the favorites rule
                    // also wants stays exactly where it is.
                    downloadManager.relinquish(trackID: track.id, by: .manual)
                }
            } else {
                // Download all tracks
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.impactOccurred()

                downloadManager.downloadAlbum(tracks: albumTracks)
            }
        }
    }

    private var downloadIconName: String {
        switch albumDownloadState {
        case .notDownloaded:
            return "arrow.down.circle"
        case .downloading:
            return "arrow.down.circle.fill"
        case .downloaded:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.circle"
        }
    }

    private var downloadIconColor: Color {
        switch albumDownloadState {
        case .notDownloaded:
            return Color.appText
        case .downloading:
            return .appAccent
        case .downloaded:
            return .appSuccess
        case .failed:
            return .red
        }
    }

    // MARK: - Background (blurred album art, like Now Playing / PWA)
    private var albumBackground: some View {
        ZStack {
            Color.appBackground
                .ignoresSafeArea()

            // Blurred album art
            if let artworkURL = album.artworkURL, let url = URL(string: artworkURL) {
                ViewportBlurredArtwork(url: url)
                .ignoresSafeArea()
            }

            // Gradient overlay for readability
            LinearGradient(
                colors: [
                    Color.appBackground.opacity(0.4),
                    Color.appBackground.opacity(0.7),
                    Color.appBackground.opacity(0.95)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    // MARK: - Album Hero Section
    private var albumHeroSection: some View {
        VStack(spacing: 0) {
            // Album Artwork with upload overlay
            ZStack(alignment: .bottomTrailing) {
                artworkView
                    .frame(width: 260, height: 260)

                // Upload button overlay
                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    ZStack {
                        Circle()
                            .fill(Color.appBackground.opacity(0.85))
                            .frame(width: 36, height: 36)
                            .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 1))
                        if isUploadingArt {
                            ProgressView()
                                .tint(.appAccent)
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: album.artworkURL == nil ? "camera.fill" : "camera")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(album.artworkURL == nil ? .appAccent : .white.opacity(0.6))
                        }
                    }
                }
                .offset(x: -8, y: -8)
                .disabled(isUploadingArt)
            }
            .onChange(of: selectedPhotoItem) { _, item in
                guard let item else { return }
                Task { await uploadSelectedPhoto(item) }
            }

            // Album Title & Artist
            VStack(spacing: 8) {
                Text(album.nameWithYear)
                    .font(.title2.weight(.bold))
                    .foregroundColor(Color.appText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.lg)

                Button {
                    NavigationCoordinator.shared.navigateToArtist(for: album)
                } label: {
                    HStack(spacing: 5) {
                        Text(album.artistName)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                    }
                    .font(.appHeadline)
                    .foregroundColor(.appSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("album-artist-link")
                .accessibilityLabel("View \(album.artistName)")
            }
            .padding(.top, 20)
            .padding(.bottom, 20)
        }
        .padding(.top, 40)
    }

    // MARK: - Artwork View (existing or uploaded)
    @ViewBuilder
    private var artworkView: some View {
        if let data = localArtworkData, let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 260, height: 260)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 1))
                .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
                .accessibilityIdentifier("album-detail-artwork")
        } else if let artworkURL = album.artworkURL, let url = URL(string: artworkURL) {
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .artworkRendering()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 260, height: 260)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 1))
                        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
                default:
                    placeholderArtwork
                }
            }
            .frame(width: 260, height: 260)
            .accessibilityIdentifier("album-detail-artwork")
        } else {
            placeholderArtwork
                .accessibilityIdentifier("album-detail-artwork")
        }
    }

    // MARK: - Upload Photo
    private func uploadSelectedPhoto(_ item: PhotosPickerItem) async {
        isUploadingArt = true
        uploadArtError = nil
        defer { isUploadingArt = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                print("❌ Failed to load photo data from picker")
                uploadArtError = "Could not load the selected photo"
                return
            }
            guard let uiImage = UIImage(data: data),
                  let jpegData = uiImage.jpegData(compressionQuality: 0.85) else {
                print("❌ Failed to convert photo to JPEG")
                uploadArtError = "Could not process the photo"
                return
            }
            print("📸 Uploading album artwork (\(jpegData.count / 1024)KB) for \(album.name)")
            try await jellyfinService.uploadImage(itemId: album.id, imageData: jpegData)
            print("✅ Album artwork uploaded successfully")
            await MainActor.run {
                localArtworkData = jpegData
            }
        } catch {
            print("❌ Album artwork upload failed: \(error)")
            uploadArtError = "Upload failed: \(error.localizedDescription)"
        }
        selectedPhotoItem = nil
    }

    // MARK: - Placeholder Artwork (#77 — hash-to-color like PWA)
    private var placeholderArtwork: some View {
        let hue = AlbumPlaceholderHelper.hue(for: album.name)
        let hue2 = (hue + 40.0).truncatingRemainder(dividingBy: 360.0)

        return RoundedRectangle(cornerRadius: 16)
            .fill(
                LinearGradient(
                    colors: [
                        Color(hue: hue / 360.0, saturation: 0.45, brightness: 0.25),
                        Color(hue: hue2 / 360.0, saturation: 0.55, brightness: 0.18)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 260, height: 260)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
            .overlay(
                VStack(spacing: 6) {
                    Text(album.name)
                        .font(.system(.headline, weight: .bold))
                        .foregroundColor(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    Text(album.artistName)
                        .font(.system(.caption))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)
                }
                .padding(20)
            )
    }

    // MARK: - Action Buttons Section
    private var actionButtonsSection: some View {
        HStack(spacing: 12) {
            // Play All Button
            Button {
                guard !albumTracks.isEmpty else { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                playerManager.play(tracks: albumTracks, startingAt: 0)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                        .font(.title3)
                    Text("Play All")
                        .font(.appBody)
                        .fontWeight(.semibold)
                }
                .foregroundColor(.appAccentText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(albumTracks.isEmpty ? Color.gray : Color.appAccent)
                )

            }
            .accessibilityLabel("Play all tracks")
            .accessibilityIdentifier("album-play-all")
            .disabled(albumTracks.isEmpty)

            // Shuffle Button
            Button {
                guard !albumTracks.isEmpty else { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                playerManager.shuffleEnabled = true
                playerManager.play(tracks: albumTracks, startingAt: 0)
            } label: {
                Image(systemName: "shuffle")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(Color.appText)
                    .frame(width: 56, height: 56)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.appControlFill)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.appTertiary.opacity(0.5), lineWidth: 1)
                            )
                    )

            }
            .accessibilityLabel("Shuffle album")
            .accessibilityIdentifier("album-shuffle")
            .disabled(albumTracks.isEmpty)

            // Favorite Button
            Button {
                toggleFavorite()
            } label: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(isFavorite ? .appSecondary : .white)
                    .frame(width: 56, height: 56)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.appControlFill)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.appSecondary.opacity(isFavorite ? 0.8 : 0.5), lineWidth: 1)
                            )
                    )

            }
            .accessibilityLabel(isFavorite ? "Remove from favorites" : "Add to favorites")
            .accessibilityIdentifier("album-favorite")

            // Download Button
            Button {
                toggleDownload()
            } label: {
                ZStack {
                    // Background
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.appControlFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(downloadIconColor.opacity(0.5), lineWidth: 1)
                        )
                        .frame(width: 56, height: 56)

                    // Icon or Progress
                    if case .downloading(let progress) = albumDownloadState {
                        // Show progress ring
                        ZStack {
                            Circle()
                                .stroke(Color.white.opacity(0.2), lineWidth: 3)

                            Circle()
                                .trim(from: 0, to: progress)
                                .stroke(downloadIconColor, lineWidth: 3)
                                .rotationEffect(.degrees(-90))

                            Text("\(Int(progress * 100))%")
                                .font(.system(.caption2, design: .monospaced).weight(.bold))
                                .foregroundColor(downloadIconColor)
                        }
                        .frame(width: 36, height: 36)
                    } else {
                        Image(systemName: downloadIconName)
                            .font(.title3.weight(.semibold))
                            .foregroundColor(downloadIconColor)
                    }
                }

            }
            .accessibilityLabel(
                isAlbumManagedByRule
                    ? "Kept by Favorites Offline"
                    : albumDownloadState.isDownloaded ? "Delete download" : "Download album"
            )
            .accessibilityIdentifier("album-download")
            .disabled(albumTracks.isEmpty || isAlbumManagedByRule)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
    }

    // MARK: - Album Info Section
    private var albumInfoSection: some View {
        HStack(spacing: 30) {
            if let year = album.year {
                InfoBadge(icon: "calendar", value: String(year))
            }

            InfoBadge(icon: "music.note.list", value: "\(albumTracks.count) tracks")

            InfoBadge(icon: "clock", value: totalDuration)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 30)
    }

    // MARK: - Track Listing Section
    private var trackListingSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tracks")
                .font(.appHeadline)
                .foregroundColor(Color.appText)
                .padding(.horizontal, 20)

            if isLoadingTracks && albumTracks.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                        .tint(.appAccent)
                    Text("Loading tracks...")
                        .font(.appCaption)
                        .foregroundColor(.appTextSecondary)
                        .padding(.leading, 12)
                    Spacer()
                }
                .padding(.vertical, 40)
            } else if albumTracks.isEmpty {
                HStack {
                    Spacer()
                    Text("No tracks found")
                        .font(.appBody)
                        .foregroundColor(.appTextSecondary)
                    Spacer()
                }
                .padding(.vertical, 40)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(albumTracks.enumerated()), id: \.element.id) { index, track in
                        AlbumTrackRow(
                            track: track,
                            trackNumber: index + 1,
                            isCurrentlyPlaying: playerManager.currentTrack?.id == track.id,
                            isPlaying: playerManager.isPlaying
                        ) {
                            // Play from this track
                            playerManager.play(tracks: albumTracks, startingAt: index)
                        } onToggleFavorite: {
                            toggleFavorite(for: track.id)
                        } onAddToPlaylist: {
                            // Add track to playlist
                            selectedTrackIds = [track.id]
                            showAddToPlaylist = true
                        }
                        .padding(.horizontal, 20)

                        if index < albumTracks.count - 1 {
                            Divider()
                                .background(Color.appControlFill)
                                .padding(.horizontal, 20)
                        }
                    }
                }
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.appSubtleFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.appAccent.opacity(0.2), lineWidth: 1)
                        )
                )
                .padding(.horizontal, 20)
            }
        }
        .padding(.bottom, 30)
    }
}

// MARK: - Info Badge Component
struct InfoBadge: View {
    let icon: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(.appAccent)

            Text(value)
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .foregroundColor(Color.appText)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .fixedSize()
        .background(
            Capsule()
                .fill(Color.appControlFill)
        )
        .overlay(
            Capsule()
                .stroke(Color.appAccent.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Album Track Row Component
struct AlbumTrackRow: View {
    let track: Track
    let trackNumber: Int
    let isCurrentlyPlaying: Bool
    let isPlaying: Bool
    let action: () -> Void
    let onToggleFavorite: () -> Void
    var onAddToPlaylist: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Button {
                action()
            } label: {
                HStack(spacing: 16) {
                // Track number or waveform indicator
                    if isCurrentlyPlaying {
                        Image(systemName: "waveform")
                            .font(.body.weight(.bold))
                            .foregroundColor(.appAccent)
                            .symbolEffect(.variableColor.iterative, isActive: isPlaying)
                            .frame(width: 28, alignment: .trailing)
                    } else {
                        Text("\(trackNumber)")
                            .font(.system(.body, design: .monospaced).weight(.bold))
                            .foregroundColor(.appAccent)
                            .frame(width: 28, alignment: .trailing)
                    }

                    // Track info
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.name)
                            .font(.appBody)
                            .foregroundColor(isCurrentlyPlaying ? .appAccent : Color.appText)
                            // Album metadata can include a filename-style artist prefix. Keep a
                            // second line available so the actual song title remains readable.
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

                        Text(track.durationFormatted)
                            .font(.appCaption)
                            .foregroundColor(.appTextSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundColor(.appAccent)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Track \(trackNumber): \(track.name), \(track.durationFormatted)")
            .accessibilityHint("Play track")
            // Identifying the row itself would name the heart beside it too.
            .accessibilityIdentifier("album-track-\(track.id)")

            Button(action: onToggleFavorite) {
                Image(systemName: track.isFavorite ? "heart.fill" : "heart")
                    .font(.body.weight(.semibold))
                    .foregroundColor(track.isFavorite ? .appSecondary : .appTextMuted)
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(track.isFavorite ? "Remove \(track.name) from favorites" : "Add \(track.name) to favorites")
            // Without an identifier of its own, the heart inherits the row's
            // and leaves two elements answering to the same name.
            .accessibilityIdentifier("album-track-favorite-\(track.id)")
        }
        .padding(.vertical, 12)
        .background(
            isCurrentlyPlaying ?
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.appAccent.opacity(0.08))
                    .padding(.horizontal, -8)
                : nil
        )
        .contextMenu {
            TrackContextMenu(track: track, onAddToPlaylist: onAddToPlaylist, offersGoToAlbum: false)
        }
        .offlineAvailability(.track(track.id))
    }
}

// MARK: - Preview
#Preview {
    AlbumDetailView(album: Album.mockAlbums[0])
}

#if DEBUG
struct AlbumDetailLayoutUITestHost: View {
    private let artworkURL = "https://ui-test.invalid/Items/ui-layout-album/Images/Primary?maxWidth=300&tag=ui-test"

    private var tracks: [Track] {
        [
            Track(
                id: "ui-album-track-1",
                name: "01. Layout Artist - A Meaningfully Long Track Name",
                artistName: "Layout Artist",
                albumName: "A Long Album Title Used for Layout Testing",
                duration: 240,
                artworkURL: artworkURL,
                indexNumber: 1,
                albumId: "ui-layout-album",
                artistId: "ui-layout-artist"
            ),
            Track(
                id: "ui-album-track-2",
                name: "02. Layout Artist - Another Long Track Name",
                artistName: "Layout Artist",
                albumName: "A Long Album Title Used for Layout Testing",
                duration: 210,
                artworkURL: artworkURL,
                indexNumber: 2,
                albumId: "ui-layout-album",
                artistId: "ui-layout-artist"
            )
        ]
    }

    var body: some View {
        NavigationStack {
            AlbumDetailView(
                album: Album(
                    id: "ui-layout-album",
                    name: "A Long Album Title Used for Layout Testing",
                    artistName: "Layout Artist",
                    artistId: "ui-layout-artist",
                    year: 2026,
                    artworkURL: artworkURL
                ),
                initialTracks: tracks
            )
        }
    }
}
#endif
