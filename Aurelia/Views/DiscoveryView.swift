//
//  DiscoveryView.swift
//  Aurelia
//
//  Personalized recommendation home powered by Jellyfin Instant Mix.
//

import SwiftUI

struct DiscoveryView: View {
    @StateObject private var viewModel: DiscoveryViewModel
    @ObservedObject private var playerManager = PlayerManager.shared
    @ObservedObject private var libraryStore = LibraryStore.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @State private var attemptedAutomaticLibraryRecovery = false

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
            Color.appBackground.ignoresSafeArea()

            if !libraryStore.hasCachedLibrary && !viewModel.hasContent {
                initialLibraryView
            } else if viewModel.isLoading && !viewModel.hasContent {
                loadingView
            } else if !viewModel.hasContent {
                emptyView
            } else {
                discoveryContent
            }
        }
        .rootTabNavigationTitle("Discover")
        .task {
            await viewModel.activate()
            if libraryStore.errorMessage != nil {
                automaticallyRecoverLibraryIfPossible()
            }
        }
        .onChange(of: playerManager.recentlyPlayedTracks) { _, _ in
            // Prepare recommendations for the next visit without replacing the
            // shelf snapshot while Discover is onscreen.
            Task { await viewModel.loadIfNeeded(publishResult: false) }
        }
        .onChange(of: libraryStore.catalogRevision) { oldRevision, newRevision in
            guard newRevision > 0, newRevision != oldRevision else { return }
            // Catalog promotion is atomic. Refresh only after its revision is
            // visible, never when a staged or failed sync merely stops.
            Task { await viewModel.refresh(force: true, publishResult: true) }
        }
        .onChange(of: libraryStore.errorMessage) { _, errorMessage in
            guard errorMessage != nil else { return }
            automaticallyRecoverLibraryIfPossible()
        }
        .onChange(of: networkMonitor.isOffline) { _, isOffline in
            guard !isOffline, libraryStore.errorMessage != nil else { return }
            automaticallyRecoverLibraryIfPossible()
        }
    }

    private var discoveryContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if !libraryStore.hasCachedLibrary {
                    libraryPreparationCard
                }

                statusBanner

                if let message = viewModel.errorMessage {
                    inlineMessage(message)
                }

                if !viewModel.shelves.isEmpty {
                    mixesShelf
                }

                if !viewModel.rediscoverTracks.isEmpty {
                    dynamicTrackShelf(
                        title: "Rediscover",
                        subtitle: "Music you loved that hasn't been in rotation lately.",
                        systemImage: "clock.arrow.circlepath",
                        tracks: viewModel.rediscoverTracks,
                        accessibilityID: "discovery-rediscover-title"
                    )
                }

                if !viewModel.offTheBeatenPathTracks.isEmpty {
                    dynamicTrackShelf(
                        title: "Off the Beaten Path",
                        subtitle: "Underplayed corners of your library, refreshed daily.",
                        systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                        tracks: viewModel.offTheBeatenPathTracks,
                        accessibilityID: "discovery-off-path-title"
                    )
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
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch viewModel.availability {
        case .checking:
            EmptyView()
        case .analyzing(let task):
            VStack(alignment: .leading, spacing: 10) {
                Label("AudioMuse is analyzing your library", systemImage: "waveform.badge.magnifyingglass")
                    .font(.appSubheadline)
                    .foregroundColor(.appText)
                if let message = task.message {
                    Text(message)
                        .font(.appCaption)
                        .foregroundColor(.appTextSecondary)
                }
                if let progress = task.progressFraction {
                    ProgressView(value: progress)
                        .tint(.appAccent)
                } else {
                    ProgressView()
                        .tint(.appAccent)
                }
                Text("Recommendations will improve as analysis completes.")
                    .font(.appCaption)
                    .foregroundColor(.appTextSecondary)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.appElevated))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.appAccent.opacity(0.3)))
            .padding(.horizontal, 20)
        case .ready:
            Label("Personalized by AudioMuse-AI", systemImage: "waveform.path.ecg")
                .font(.appCaption)
                .foregroundColor(.appTextSecondary)
                .padding(.horizontal, 20)
        case .notInstalled:
            Label("AudioMuse-AI is required for Daily Mixes", systemImage: "waveform.path.badge.exclamationmark")
                .font(.appCaption)
                .foregroundColor(.appTextSecondary)
                .padding(.horizontal, 20)
        case .unavailable:
            Label("AudioMuse-AI is temporarily unavailable", systemImage: "waveform.path.badge.exclamationmark")
                .font(.appCaption)
                .foregroundColor(.appTextSecondary)
                .padding(.horizontal, 20)
        }
    }

    private var recentPlaysShelf: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Recently Played")
                .font(.appTitle)
                .foregroundColor(.appText)
                .padding(.horizontal, 20)
                .accessibilityIdentifier("discovery-recent-title")

            trackScroller(viewModel.recentTracks)
        }
    }

    private var mixesShelf: some View {
        VStack(alignment: .leading, spacing: 14) {
            shelfHeader(
                title: "Your Daily Mixes",
                subtitle: "Familiar favorites and nearby discoveries, refreshed daily.",
                systemImage: "sparkles",
                tracks: nil,
                accessibilityID: "discovery-mixes-title"
            )

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
                            .tint(nil)

                            Divider()

                            TrackContextMenu(track: shelf.seed, offersInstantMix: false)
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
            .scrollClipDisabled()
        }
    }

    private func dynamicTrackShelf(
        title: String,
        subtitle: String,
        systemImage: String,
        tracks: [Track],
        accessibilityID: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            shelfHeader(
                title: title,
                subtitle: subtitle,
                systemImage: systemImage,
                tracks: tracks,
                accessibilityID: accessibilityID
            )
            trackScroller(tracks)
        }
    }

    private func shelfHeader(
        title: String,
        subtitle: String,
        systemImage: String,
        tracks: [Track]?,
        accessibilityID: String
    ) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Label(title, systemImage: systemImage)
                    .font(.appTitle)
                    .foregroundColor(.appText)
                    .accessibilityIdentifier(accessibilityID)
                Text(subtitle)
                    .font(.appCaption)
                    .foregroundColor(.appTextSecondary)
            }

            Spacer(minLength: 8)

            if let tracks, !tracks.isEmpty {
                Button {
                    startPlayback(tracks, startingAt: 0)
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(.appSubheadline)
                        .foregroundColor(.appAccentText)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.appAccent))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
    }

    private var fallbackShelf: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Start listening")
                    .font(.appTitle)
                    .foregroundColor(.appText)
                Text("Instant Mix will learn from what you play.")
                    .font(.appCaption)
                    .foregroundColor(.appTextSecondary)
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
            if let progress = libraryStore.syncProgress {
                ProgressView(value: progress)
                    .tint(.appAccent)
                    .frame(maxWidth: 300)
            } else {
                ProgressView()
                    .tint(.appAccent)
                    .scaleEffect(1.3)
            }
            Text(libraryStore.syncMessage ?? "Finding music for you…")
                .font(.appBody)
                .foregroundColor(.appTextSecondary)
            if let progress = libraryStore.syncProgress {
                Text("\(Int(progress * 100))%")
                    .font(.appMono)
                    .foregroundColor(.appTextMuted)
            }
        }
        .padding(.horizontal, 24)
    }

    private var initialLibraryView: some View {
        ScrollView {
            VStack(spacing: 24) {
                libraryPreparationCard
                if let message = viewModel.errorMessage {
                    inlineMessage(message)
                }
            }
            .padding(.top, 24)
        }
    }

    private var libraryPreparationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Preparing your library", systemImage: "sparkles")
                .font(.appHeadline)
                .foregroundColor(.appText)

            Text(libraryStore.errorMessage ?? libraryStore.syncMessage ?? "Getting your music ready…")
                .font(.appBody)
                .foregroundColor(.appTextSecondary)

            if let progress = libraryStore.syncProgress {
                ProgressView(value: progress)
                    .tint(.appAccent)
                Text("\(Int(progress * 100))%")
                    .font(.appMono)
                    .foregroundColor(.appTextMuted)
            } else if libraryStore.errorMessage == nil {
                ProgressView()
                    .tint(.appAccent)
            }

            Text("Recently Played is available now. Daily Mixes, Rediscover, and Off the Beaten Path will appear automatically when preparation finishes.")
                .font(.appCaption)
                .foregroundColor(.appTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if libraryStore.errorMessage != nil {
                Button("Try Again") {
                    Task { await recoverLibrary() }
                }
                .font(.appSubheadline)
                .foregroundColor(.appAccentText)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Capsule().fill(Color.appAccent))
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.appElevated))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.appAccent.opacity(0.25)))
        .padding(.horizontal, 20)
        .accessibilityIdentifier("discovery-library-preparation")
    }

    private func automaticallyRecoverLibraryIfPossible() {
        guard !attemptedAutomaticLibraryRecovery,
              !libraryStore.isRefreshing,
              !libraryStore.hasCachedLibrary else { return }
        attemptedAutomaticLibraryRecovery = true
        Task {
            await recoverLibrary()
            // A genuine offline failure can try again when NetworkMonitor
            // reports the path/server back. Successful recovery needs no arm.
            attemptedAutomaticLibraryRecovery = libraryStore.errorMessage == nil
        }
    }

    private func recoverLibrary() async {
        // The sync request itself is the most useful reachability check. It
        // also clears the previous error immediately, so retry visibly starts.
        await libraryStore.refresh(trigger: .manual)
        if libraryStore.errorMessage == nil {
            await viewModel.refresh(force: true, publishResult: true)
            await viewModel.updateAudioMuseStatus()
        }
    }

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 42))
                .foregroundStyle(Color.appAccent)
            Text("Nothing to recommend yet")
                .font(.appHeadline)
                .foregroundColor(.appText)
            Text(viewModel.errorMessage ?? "Play a few songs, then come back to Discover.")
                .font(.appBody)
                .foregroundColor(.appTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Try Again") {
                Task { await viewModel.refresh() }
            }
            .font(.appSubheadline)
            .foregroundColor(.appAccentText)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color.appAccent))
        }
    }

    private func inlineMessage(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.appCaption)
            .foregroundColor(.appTextSecondary)
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
                            colors: [Color.appAccent.opacity(0.35), Color.appSecondary.opacity(0.3)],
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
                    .foregroundColor(.appAccentText)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Color.appAccent))
                    .padding(10)
            }
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.appControlFill))

            Text(shelf.mixTitle)
                .font(.appSubheadline)
                .foregroundColor(.appText)
                .lineLimit(1)
            Text(shelf.supportingArtistNames.joined(separator: ", "))
                .font(.appCaption)
                .foregroundColor(.appTextSecondary)
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
                        Color.appElevated
                        Image(systemName: "music.note")
                            .font(.title)
                            .foregroundColor(.appTextMuted)
                    }
                }
            }
            .frame(width: 150, height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.appControlFill))

            Text(track.name)
                .font(.appSubheadline)
                .foregroundColor(.appText)
                .lineLimit(1)
            Text(track.artistName)
                .font(.appCaption)
                .foregroundColor(.appTextSecondary)
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
