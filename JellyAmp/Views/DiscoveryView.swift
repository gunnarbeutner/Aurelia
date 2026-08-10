//
//  DiscoveryView.swift
//  JellyAmp
//
//  Personalized recommendation home powered by Jellyfin Instant Mix.
//

import SwiftUI

struct DiscoveryView: View {
    @StateObject private var viewModel = DiscoveryViewModel()
    @ObservedObject private var playerManager = PlayerManager.shared

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
        .navigationBarTitleDisplayMode(.large)
        .task {
            await viewModel.activate()
        }
        .onChange(of: playerManager.recentlyPlayedTracks) { _, _ in
            Task { await viewModel.loadIfNeeded() }
        }
    }

    private var discoveryContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                statusBanner

                if let message = viewModel.errorMessage {
                    inlineMessage(message)
                }

                ForEach(viewModel.shelves) { shelf in
                    recommendationShelf(shelf)
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

    private func recommendationShelf(_ shelf: DiscoveryShelf) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Because you played")
                        .font(.jellyAmpCaption)
                        .foregroundColor(.jellyAmpTextSecondary)
                    Text(shelf.seed.name)
                        .font(.jellyAmpTitle)
                        .foregroundColor(.jellyAmpText)
                        .lineLimit(1)
                    Text(shelf.seed.artistName)
                        .font(.jellyAmpCaption)
                        .foregroundColor(.neonPink)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                Button {
                    playerManager.play(tracks: shelf.tracks)
                } label: {
                    Image(systemName: "play.fill")
                        .font(.headline)
                        .foregroundColor(.black)
                        .frame(width: 42, height: 42)
                        .background(Circle().fill(Color.neonCyan))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play recommendations for \(shelf.seed.name)")
            }
            .padding(.horizontal, 20)

            trackScroller(shelf.tracks)
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
                        playerManager.play(tracks: tracks, startingAt: index)
                    } label: {
                        DiscoveryTrackCard(track: track)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        InstantMixButton(itemId: track.id, itemName: track.name)

                        Button {
                            playerManager.playNext(track: track)
                        } label: {
                            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                        }
                        Button {
                            playerManager.addToQueue(track: track)
                        } label: {
                            Label("Add to Queue", systemImage: "text.badge.plus")
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
        }
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
