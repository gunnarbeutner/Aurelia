//
//  FavoritesView.swift
//  Aurelia
//
//  Favorites page — redesigned to match PWA with filter pills and sections
//

import SwiftUI

struct FavoritesView: View {
    @ObservedObject var playerManager = PlayerManager.shared
    @ObservedObject private var mutationCenter = FavoriteMutationCenter.shared
    @ObservedObject private var libraryStore = LibraryStore.shared
    @StateObject private var viewModel: FavoritesViewModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedFilter = "All"
    let isActive: Bool

    private let filters = ["All", "Artists", "Albums", "Tracks"]

    init(isActive: Bool = true) {
        self.isActive = isActive
        _viewModel = StateObject(wrappedValue: FavoritesViewModel())
    }

    private var columns: [GridItem] {
        sizeClass == .regular
            ? [GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 16)]
            : [GridItem(.adaptive(minimum: 130), spacing: 16)]
    }

    var body: some View {
        ZStack {
            Color.appBackground
                .ignoresSafeArea()

            if viewModel.isInitialLoading {
                VStack(spacing: 16) {
                    ProgressView()
                        .tint(.appSecondary)
                        .scaleEffect(1.5)
                    Text("Loading favorites...")
                        .font(.appBody)
                        .foregroundColor(.appTextSecondary)
                }
            } else {
                ScrollView {
                    if viewModel.isEmpty {
                        emptyStateView
                    } else {
                        favoritesContent
                    }
                }
                .scrollBounceBehavior(.always)
            }
        }
        .navigationDestination(for: Album.self) { album in
            AlbumDetailView(album: album)
        }
        .navigationDestination(for: Artist.self) { artist in
            ArtistDetailView(artist: artist)
        }
        .rootTabNavigationTitle("Favorites")
        .onAppear {
            if isActive {
                Task { await viewModel.activate() }
            }
        }
        .onChange(of: isActive) { _, active in
            guard active else { return }
            Task { await viewModel.activate() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active && isActive {
                Task { await viewModel.activate() }
            }
        }
        .onChange(of: libraryStore.catalogRevision) { _, _ in
            guard isActive else { return }
            Task { await viewModel.refresh() }
        }
        .onReceive(mutationCenter.$latestEvent) { event in
            guard let event else { return }
            viewModel.apply(event.mutation)
        }
    }

    // MARK: - Computed
    private var favoriteTracks: [Track] { viewModel.tracks }
    private var favoriteAlbums: [Album] { viewModel.albums }
    private var favoriteArtists: [Artist] { viewModel.artists }
    private var showArtists: Bool { selectedFilter == "All" || selectedFilter == "Artists" }
    private var showAlbums: Bool { selectedFilter == "All" || selectedFilter == "Albums" }
    private var showTracks: Bool { selectedFilter == "All" || selectedFilter == "Tracks" }

    // MARK: - Header
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(favoriteArtists.count) artists · \(favoriteAlbums.count) albums · \(favoriteTracks.count) tracks")
                .font(.appMono)
                .foregroundColor(.appTextSecondary)
        }
    }

    private var favoritesContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
                .padding(.horizontal, 20)
                .padding(.bottom, 16)

            filterPills
                .padding(.horizontal, 20)
                .padding(.bottom, 24)

            VStack(alignment: .leading, spacing: 32) {
                if showArtists {
                    artistsSection
                }
                if showAlbums {
                    albumsSection
                }
                if showTracks {
                    tracksSection
                }
            }
            .padding(.horizontal, 20)

            Color.clear.frame(height: 100)
        }
    }

    // MARK: - Filter Pills
    private var filterPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(filters, id: \.self) { filter in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedFilter = filter
                        }
                    } label: {
                        Text(filter)
                            .font(.appCaption)
                            .fontWeight(.medium)
                            .foregroundColor(selectedFilter == filter ? .appAccentText : .appTextSecondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(selectedFilter == filter ? Color.appAccent : Color.appControlFill)
                            )
                            .overlay(
                                Capsule()
                                    .stroke(selectedFilter == filter ? Color.clear : Color.appControlFill, lineWidth: 1)
                            )
                    }
                }
            }
        }
    }

    // MARK: - Artists Section
    private var artistsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if selectedFilter == "All" {
                sectionHeader(title: "Favorite Artists", count: favoriteArtists.count)
            }

            if favoriteArtists.isEmpty {
                sectionEmpty("No favorite artists yet")
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(favoriteArtists) { artist in
                        NavigationLink(value: artist) {
                            ArtistCard(artist: artist)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Albums Section
    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if selectedFilter == "All" {
                sectionHeader(title: "Favorite Albums", count: favoriteAlbums.count)
            }

            if favoriteAlbums.isEmpty {
                sectionEmpty("No favorite albums yet")
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(favoriteAlbums) { album in
                        NavigationLink(value: album) {
                            AlbumCard(album: album)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Tracks Section
    private var tracksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if selectedFilter == "All" {
                HStack {
                    sectionHeader(title: "Favorite Tracks", count: favoriteTracks.count)
                    Spacer()
                    if !favoriteTracks.isEmpty {
                        Button {
                            playerManager.play(tracks: favoriteTracks)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "play.fill")
                                    .font(.caption2)
                                Text("Play All")
                                    .font(.appCaption)
                                    .fontWeight(.medium)
                            }
                            .foregroundColor(.appTextSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.appControlFill)
                            )
                        }
                    }
                }
            }

            if favoriteTracks.isEmpty {
                sectionEmpty("No favorite tracks yet")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(favoriteTracks.enumerated()), id: \.element.id) { index, track in
                        FavoriteTrackRow(track: track) {
                            playerManager.play(tracks: favoriteTracks, startingAt: index)
                        }

                        if index < favoriteTracks.count - 1 {
                            Divider()
                                .background(Color.appSubtleFill)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Section Components
    private func sectionHeader(title: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.appHeadline)
                .foregroundColor(Color.appText)
            Text("(\(count))")
                .font(.appCaption)
                .foregroundColor(.appTextMuted)
        }
    }

    private func sectionEmpty(_ text: String) -> some View {
        Text(text)
            .font(.appCaption)
            .foregroundColor(.appTextMuted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
    }

    // MARK: - Empty State
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "heart")
                .font(.system(size: 48))
                .foregroundColor(.appTextSecondary)
            Text("No Favorites Yet")
                .font(.appTitle)
                .foregroundColor(Color.appText)
            Text("Tap the heart on albums, artists, and tracks to add them here.")
                .font(.appBody)
                .foregroundColor(.appTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
        .padding(.bottom, 260)
    }

}

// MARK: - Favorite Track Row
struct FavoriteTrackRow: View {
    let track: Track
    let action: () -> Void
    @ObservedObject var playerManager = PlayerManager.shared

    private var isCurrentlyPlaying: Bool {
        playerManager.currentTrack?.id == track.id
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // Artwork
                Group {
                    if let artworkURL = track.artworkURL, let url = URL(string: artworkURL) {
                        CachedAsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().aspectRatio(contentMode: .fill)
                            default:
                                placeholderArtwork
                            }
                        }
                    } else {
                        placeholderArtwork
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.appControlFill, lineWidth: 1)
                )

                // Now playing indicator
                if isCurrentlyPlaying {
                    Image(systemName: "waveform")
                        .font(.caption.weight(.bold))
                        .foregroundColor(.appAccent)
                        .symbolEffect(.variableColor.iterative, isActive: playerManager.isPlaying)
                        .frame(width: 16)
                }

                // Info
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(isCurrentlyPlaying ? .appAccent : .appText)
                        .lineLimit(1)
                    Text(track.artistName)
                        .font(.caption)
                        .foregroundColor(.appTextSecondary)
                        .lineLimit(1)
                }

                Spacer()

                Text(track.durationFormatted)
                    .font(.appMono)
                    .foregroundColor(.appTextSecondary)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            TrackContextMenu(track: track)
        }
        .offlineAvailability(.track(track.id))
    }

    private var placeholderArtwork: some View {
        Rectangle()
            .fill(Color.appMidBackground)
            .overlay {
                Image(systemName: "music.note")
                    .font(.caption)
                    .foregroundColor(.appTextSecondary)
            }
    }
}

#Preview {
    FavoritesView()
}
