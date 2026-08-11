//
//  DiscoveryView.swift
//  JellyAmp
//
//  Personalized recommendation home powered by Jellyfin Instant Mix.
//

import SwiftUI

struct DiscoveryView: View {
    @StateObject private var viewModel: DiscoveryViewModel
    @ObservedObject private var playerManager = PlayerManager.shared

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-player-layout") {
            let seed = Track(
                id: "ui-layout-seed",
                name: "Layout Seed",
                artistName: "Layout Artist",
                albumName: "Layout Album",
                duration: 180,
                artworkURL: nil,
                albumId: "ui-layout-album",
                artistId: "ui-layout-artist"
            )
            _viewModel = StateObject(
                wrappedValue: DiscoveryViewModel(
                    api: PlayerLayoutDiscoveryAPI(),
                    recentTracksProvider: { [seed] }
                )
            )
            return
        }
        #endif

        _viewModel = StateObject(wrappedValue: DiscoveryViewModel())
    }

    var body: some View {
        ZStack {
            Color.jellyAmpBackground.ignoresSafeArea()

            if viewModel.isLoading && !viewModel.hasContent {
                loadingView
            } else if !viewModel.hasContent {
                emptyView
            } else {
                discoveryContent
            }
        }
        .navigationTitle("Discover")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.activate()
        }
        .onChange(of: playerManager.recentlyPlayedTracks) { _, _ in
            // Prepare recommendations for the next visit without replacing the
            // shelf snapshot while Discover is onscreen.
            Task { await viewModel.loadIfNeeded(publishResult: false) }
        }
    }

    private var discoveryContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                statusBanner

                if let message = viewModel.errorMessage {
                    inlineMessage(message)
                }

                if !viewModel.shelves.isEmpty {
                    mixesShelf
                }

                if !viewModel.recentTracks.isEmpty {
                    recentPlaysShelf
                }

                if !viewModel.fallbackTracks.isEmpty {
                    fallbackShelf
                }

                Color.clear.frame(height: 100)
            }
            .padding(.top, 8)
        }
        .refreshable {
            await viewModel.refresh()
            await viewModel.updateAudioMuseStatus()
        }
        .overlay(alignment: .topTrailing) {
            if viewModel.isRefreshing {
                ProgressView()
                    .tint(.neonCyan)
                    .padding(20)
            }
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch viewModel.availability {
        case .checking:
            EmptyView()
        case .analyzing(let task):
            VStack(alignment: .leading, spacing: 10) {
                Label("AudioMuse is analyzing your library", systemImage: "waveform.badge.magnifyingglass")
                    .font(.jellyAmpSubheadline)
                    .foregroundColor(.jellyAmpText)
                if let message = task.message {
                    Text(message)
                        .font(.jellyAmpCaption)
                        .foregroundColor(.jellyAmpTextSecondary)
                }
                if let progress = task.progressFraction {
                    ProgressView(value: progress)
                        .tint(.neonCyan)
                } else {
                    ProgressView()
                        .tint(.neonCyan)
                }
                Text("Recommendations will improve as analysis completes.")
                    .font(.jellyAmpCaption)
                    .foregroundColor(.jellyAmpTextSecondary)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.jellyAmpElevated))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.neonCyan.opacity(0.3)))
            .padding(.horizontal, 20)
        case .ready:
            Label("Personalized by AudioMuse-AI", systemImage: "waveform.path.ecg")
                .font(.jellyAmpCaption)
                .foregroundColor(.jellyAmpTextSecondary)
                .padding(.horizontal, 20)
        case .notInstalled, .unavailable:
            Label("Using Jellyfin Instant Mix", systemImage: "sparkles")
                .font(.jellyAmpCaption)
                .foregroundColor(.jellyAmpTextSecondary)
                .padding(.horizontal, 20)
        }
    }

    private var recentPlaysShelf: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Recently Played")
                .font(.jellyAmpTitle)
                .foregroundColor(.jellyAmpText)
                .padding(.horizontal, 20)
                .accessibilityIdentifier("discovery-recent-title")

            trackScroller(viewModel.recentTracks)
        }
    }

    private var mixesShelf: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Mixes")
                .font(.jellyAmpTitle)
                .foregroundColor(.jellyAmpText)
                .padding(.horizontal, 20)
                .accessibilityIdentifier("discovery-mixes-title")

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(viewModel.shelves) { shelf in
                        Button {
                            startPlayback(shelf.tracks, startingAt: 0)
                        } label: {
                            DiscoveryMixCard(shelf: shelf)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("discovery-mix-\(shelf.id)")
                        .accessibilityLabel("Play \(shelf.mixTitle)")
                        .contextMenu {
                            Button {
                                startPlayback(shelf.tracks, startingAt: 0)
                            } label: {
                                Label("Play Mix", systemImage: "play.fill")
                            }

                            Divider()

                            TrackContextMenu(track: shelf.seed)
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
            .scrollClipDisabled()
        }
    }

    private var fallbackShelf: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Start listening")
                    .font(.jellyAmpTitle)
                    .foregroundColor(.jellyAmpText)
                Text("Instant Mix will learn from what you play.")
                    .font(.jellyAmpCaption)
                    .foregroundColor(.jellyAmpTextSecondary)
            }
            .padding(.horizontal, 20)

            trackScroller(viewModel.fallbackTracks)
        }
    }

    private func trackScroller(_ tracks: [Track]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    Button {
                        startPlayback(tracks, startingAt: index)
                    } label: {
                        DiscoveryTrackCard(track: track)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("discovery-track-\(track.id)")
                    .contextMenu {
                        TrackContextMenu(track: track)
                    }
                }
            }
            .padding(.horizontal, 20)
        }
        // Context-menu previews lift beyond the horizontal shelf's bounds.
        // The default scroll clipping otherwise cuts off their top edge.
        .scrollClipDisabled()
    }

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .tint(.neonCyan)
                .scaleEffect(1.3)
            Text("Finding music for you…")
                .font(.jellyAmpBody)
                .foregroundColor(.jellyAmpTextSecondary)
        }
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 42))
                .foregroundStyle(Color.neonCyan)
            Text("Nothing to recommend yet")
                .font(.jellyAmpHeadline)
                .foregroundColor(.jellyAmpText)
            Text(viewModel.errorMessage ?? "Play a few songs, then come back to Discover.")
                .font(.jellyAmpBody)
                .foregroundColor(.jellyAmpTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Try Again") {
                Task { await viewModel.refresh() }
            }
            .font(.jellyAmpSubheadline)
            .foregroundColor(.black)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color.neonCyan))
        }
    }

    private func inlineMessage(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.jellyAmpCaption)
            .foregroundColor(.jellyAmpTextSecondary)
            .padding(.horizontal, 20)
    }

    private func startPlayback(_ tracks: [Track], startingAt index: Int) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-player-layout"),
           tracks.indices.contains(index) {
            playerManager.queue = tracks
            playerManager.currentIndex = index
            playerManager.currentTrack = tracks[index]
            playerManager.duration = tracks[index].duration
            return
        }
        #endif

        playerManager.play(tracks: tracks, startingAt: index)
    }
}

private struct DiscoveryMixCard: View {
    let shelf: DiscoveryShelf

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CachedAsyncImage(url: shelf.seed.artworkURL.flatMap(URL.init(string:))) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    ZStack {
                        LinearGradient(
                            colors: [Color.neonCyan.opacity(0.35), Color.neonPink.opacity(0.3)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        Image(systemName: "waveform")
                            .font(.system(size: 38, weight: .semibold))
                            .foregroundColor(.white.opacity(0.75))
                    }
                }
            }
            .frame(width: 170, height: 170)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "play.fill")
                    .font(.headline)
                    .foregroundColor(.black)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Color.neonCyan))
                    .padding(10)
            }
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08)))

            Text(shelf.mixTitle)
                .font(.jellyAmpSubheadline)
                .foregroundColor(.jellyAmpText)
                .lineLimit(1)
            Text(shelf.supportingArtistNames.joined(separator: ", "))
                .font(.jellyAmpCaption)
                .foregroundColor(.jellyAmpTextSecondary)
                .lineLimit(2)
        }
        .frame(width: 170, alignment: .leading)
    }
}

private struct DiscoveryTrackCard: View {
    let track: Track

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CachedAsyncImage(url: track.artworkURL.flatMap(URL.init(string:))) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    ZStack {
                        Color.jellyAmpElevated
                        Image(systemName: "music.note")
                            .font(.title)
                            .foregroundColor(.jellyAmpTextMuted)
                    }
                }
            }
            .frame(width: 150, height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08)))

            Text(track.name)
                .font(.jellyAmpSubheadline)
                .foregroundColor(.jellyAmpText)
                .lineLimit(1)
            Text(track.artistName)
                .font(.jellyAmpCaption)
                .foregroundColor(.jellyAmpTextSecondary)
                .lineLimit(1)
        }
        .frame(width: 150, alignment: .leading)
    }
}

#Preview {
    NavigationStack {
        DiscoveryView()
    }
}
