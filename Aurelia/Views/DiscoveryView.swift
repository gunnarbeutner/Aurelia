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
    /// Server-fetched artwork shown only while the library is being prepared.
    /// Never read once the real catalogue lands.
    @State private var previewAlbums: [Album] = []
    @State private var showsCoverWall = false
    /// The album started from the wall, so a second tap on it stops.
    @State private var playingAlbumID: String?
    /// True from catalogue promotion until the refresh it triggers returns.
    @State private var isRefreshingAfterPromotion = false
    /// What the bar actually draws. Only ever moves forward: the sync stops
    /// reporting a figure the moment the catalogue is promoted, and a bar that
    /// drops to nothing on the way to finishing reads as a failure.
    @State private var shownProgress: Double = 0
    @State private var showsDiscoveryErrorDetails = false
    @AppStorage(LibraryStore.hasEverSyncedKey) private var hasEverSynced = false
    /// True while the first-run screen is actually on display.
    @State private var isShowingPreparation = false

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
                    recentTracksProvider: { [seed] },
                    snapshotScope: LibraryScope(
                        baseURL: PlayerLayoutDiscoveryAPI().baseURL,
                        userID: "ui-test"
                    ),
                    candidateProvider: PlayerLayoutDiscoveryCandidates()
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

            if showsPreparationSection {
                preparingView
            } else if viewModel.isLoading && !viewModel.hasContent {
                loadingView
            } else if !viewModel.hasContent {
                emptyView
            } else {
                discoveryContent
            }
        }
        .rootTabNavigationTitle("Discover")
        // Preparation owns the screen, and a tab title is chrome for a tab you
        // cannot currently leave. Catalyst has no navigation bar here to begin
        // with — `rootTabNavigationTitle` hides it — and asking for one back
        // reserves space for a bar that never draws.
        #if !targetEnvironment(macCatalyst)
        .toolbar(showsPreparationSection ? .hidden : .visible, for: .navigationBar)
        #endif
        .onAppear {
            isShowingPreparation = showsPreparationSection
            LibraryPreparation.shared.isActive = showsPreparationSection
        }
        .onChange(of: showsPreparationSection) { _, isPreparing in
            isShowingPreparation = isPreparing
            LibraryPreparation.shared.isActive = isPreparing
        }
        .onChange(of: libraryStore.syncProgress) { _, progress in
            advanceProgress(to: (progress ?? 0) * 0.9, duration: 0.3)
        }
        .onChange(of: isBuildingMixes) { _, isBuilding in
            guard isBuilding else { return }
            Task { await crawlThroughFinalStretch() }
        }
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
            // Reading the stored snapshot at launch also advances the revision,
            // and that is not a promotion. The mixes phase only ever extends a
            // takeover that is already on screen.
            if isShowingPreparation {
                isRefreshingAfterPromotion = true
            }
            Task {
                await viewModel.refresh(force: true, publishResult: true)
                isRefreshingAfterPromotion = false
            }
        }
        .onChange(of: libraryStore.errorMessage) { _, errorMessage in
            guard errorMessage != nil else { return }
            automaticallyRecoverLibraryIfPossible()
        }
        .onChange(of: networkMonitor.isOffline) { _, isOffline in
            guard !isOffline, libraryStore.errorMessage != nil else { return }
            automaticallyRecoverLibraryIfPossible()
        }
        .alert("Daily Mix Refresh", isPresented: $showsDiscoveryErrorDetails) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorDetails ?? viewModel.errorMessage ?? "The refresh failed.")
        }
    }

    private var discoveryContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if let message = viewModel.errorMessage {
                    inlineMessage(message)
                }

                if !viewModel.shelves.isEmpty {
                    mixesShelf
                } else if missingMixesNeedExplaining {
                    missingMixesNote
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

    /// Said in the shelf's own place rather than as a banner up top. Without
    /// it the Daily Mixes simply would not exist, with nothing to say why —
    /// worse than the notice this replaces, which at least explained itself.
    private var missingMixesNeedExplaining: Bool {
        viewModel.availability == .notInstalled || viewModel.availability == .unavailable
    }

    private var missingMixesNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Daily Mixes")
                .font(.appTitle)
                .foregroundColor(.appText)

            Text(viewModel.availability == .notInstalled
                 ? "Needs the AudioMuse-AI plugin on your server."
                 : "AudioMuse-AI is not responding right now.")
                .font(.appCaption)
                .foregroundColor(.appTextSecondary)
        }
        .padding(.horizontal, 20)
        .accessibilityIdentifier("discovery-missing-mixes-note")
    }

    private var recentPlaysShelf: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Recently Played")
                .font(.appTitle)
                .foregroundColor(.appText)
                .padding(.horizontal, 20)
                .accessibilityIdentifier("discovery-recent-title")

            recentPlayScroller(Array(RecentPlayGrouping.group(viewModel.recentTracks).prefix(12)))
        }
    }

    private func recentPlayScroller(_ items: [RecentPlayItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                ForEach(items) { item in
                    Button {
                        startRecentPlayback(item)
                    } label: {
                        RecentPlayCard(item: item)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("discovery-recent-\(item.id)")
                    .accessibilityLabel(
                        item.isAlbumSession ? "Resume album \(item.title)" : "Play \(item.title)"
                    )
                    .contextMenu {
                        if let album = item.album {
                            AlbumContextMenu(album: album)
                        } else {
                            TrackContextMenu(track: item.resumeTrack)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollClipDisabled()
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
                            startPlayback(shelf.playbackTracks, startingAt: 0)
                        } label: {
                            DiscoveryMixCard(shelf: shelf)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("discovery-mix-\(shelf.id)")
                        .accessibilityLabel("Play \(shelf.mixTitle)")
                        .contextMenu {
                            Button {
                                startPlayback(shelf.playbackTracks, startingAt: 0)
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

    /// Preparation takes the whole screen and holds it until Discover has
    /// something real to say.
    ///
    /// Nothing else is on screen while this runs, and it does not scroll:
    /// there is no shelf worth showing beside a progress bar, and no content
    /// below to scroll to. Discover appears once, complete.
    private var preparingView: some View {
        VStack(spacing: 24) {
            libraryPreparationCard

            // The wall takes whatever is left and fills it: the grid is sized
            // from the space available rather than a fixed count, so it reaches
            // the bottom of any screen it lands on.
            GeometryReader { proxy in
                coverWall(in: proxy.size)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .padding(.top, 8)
        .task {
            await loadLibraryPreview()
        }
    }

    /// Albums pulled straight from the server, revealed in step with the sync.
    ///
    /// The wall is the progress: the bar above it is a hairline, and what the
    /// listener actually watches is their own artwork arriving. Purely
    /// decorative — nothing here is used once the real catalogue is promoted.
    @ViewBuilder
    private func coverWall(in size: CGSize) -> some View {
        if showsCoverWall, !previewAlbums.isEmpty {
            let layout = coverWallLayout(in: size)
            let albums = Array(previewAlbums.prefix(layout.count))
            let revealed = revealedCoverCount(of: albums.count)

            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.fixed(layout.tile), spacing: Self.coverWallSpacing),
                    count: layout.columns
                ),
                spacing: Self.coverWallSpacing
            ) {
                ForEach(Array(albums.enumerated()), id: \.element.id) { index, album in
                    coverTile(for: album, state: CoverTileState(index: index, revealed: revealed))
                }
            }
            .padding(.horizontal, Self.coverWallPadding)
            .overlay(alignment: .topLeading) { sweep(over: layout, tiles: albums.count) }
            .transition(.opacity)
        }
    }

    private static let coverWallSpacing: CGFloat = 8
    private static let coverWallPadding: CGFloat = 20

    /// A light travelling the wall cover by cover while the mixes are worked
    /// out — along a row, then on to the next, in reading order.
    ///
    /// Drawn as one moving highlight rather than an effect on each tile, so
    /// the covers themselves are never re-rendered and nothing shifts or
    /// resizes underneath it.
    @ViewBuilder
    private func sweep(over layout: (columns: Int, tile: CGFloat, count: Int), tiles: Int) -> some View {
        if isBuildingMixes, tiles > 0 {
            TimelineView(.animation) { context in
                let step = 0.16
                let elapsed = context.date.timeIntervalSinceReferenceDate / step
                // The cycle runs past the last cover to leave a beat before it
                // starts again. The light is not drawn during that beat — it
                // has no cover left to be on.
                let position = elapsed.truncatingRemainder(dividingBy: Double(tiles) + 3)
                let isOverWall = position < Double(tiles)
                let column = position.truncatingRemainder(dividingBy: Double(layout.columns))
                let row = (position / Double(layout.columns)).rounded(.down)
                let pitch = layout.tile + Self.coverWallSpacing

                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.appAccent.opacity(0.5))
                    .frame(width: layout.tile, height: layout.tile)
                    .blur(radius: layout.tile * 0.35)
                    .position(
                        x: column * pitch + layout.tile / 2,
                        y: row * pitch + layout.tile / 2
                    )
                    .opacity(isOverWall ? 1 : 0)
                    .blendMode(.plusLighter)
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }

    /// The cover at the head of the queue is drawn out of focus, so the wall
    /// reads as one arriving continuously rather than a row of things blinking
    /// into place.
    private enum CoverTileState {
        case waiting
        case arriving
        case landed

        init(index: Int, revealed: Int) {
            if index < revealed {
                self = .landed
            } else if index == revealed {
                self = .arriving
            } else {
                self = .waiting
            }
        }

        var opacity: Double {
            switch self {
            case .waiting: return 0
            case .arriving: return 0.45
            case .landed: return 1
            }
        }

        var blur: CGFloat {
            switch self {
            case .waiting: return 8
            case .arriving: return 6
            case .landed: return 0
            }
        }

        var scale: CGFloat {
            switch self {
            case .waiting: return 0.9
            case .arriving: return 0.96
            case .landed: return 1
            }
        }
    }

    /// How many square tiles of what size fill the space the wall was given.
    private func coverWallLayout(in size: CGSize) -> (columns: Int, tile: CGFloat, count: Int) {
        let spacing = Self.coverWallSpacing
        let width = max(size.width - Self.coverWallPadding * 2, 1)
        let columns = max(3, Int(width / 100))
        let tile = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let rows = max(1, Int((size.height + spacing) / (tile + spacing)))
        return (columns, tile, columns * rows)
    }

    /// Promotion of the catalogue and arrival of the mixes are separate events
    /// several seconds apart, and preparation covers both.
    ///
    /// The wait is for the refresh that promotion kicks off, not for shelves to
    /// exist: daily mixes need AudioMuse's analysis, which can run for hours,
    /// and Discover explains that shortfall itself once it is on screen.
    private var isBuildingMixes: Bool {
        libraryStore.hasCachedLibrary
            && isRefreshingAfterPromotion
            && libraryStore.errorMessage == nil
    }

    /// The sync fills the first nine tenths; the last tenth belongs to the
    /// refresh behind it, which reports no progress of its own and so is eased
    /// across rather than measured.
    private var preparationProgress: Double { shownProgress }

    private func advanceProgress(to value: Double, duration: Double) {
        guard value > shownProgress else { return }
        withAnimation(.easeOut(duration: duration)) { shownProgress = value }
    }

    /// Walks the last stretch a point at a time.
    ///
    /// The refresh reports nothing to measure, so the bar keeps moving on its
    /// own — in steps rather than one long glide, so the figure beside it has
    /// real values to show along the way. It stops short of full: reaching 100
    /// while the screen is still up would say the wait is over when it is not.
    private func crawlThroughFinalStretch() async {
        while isBuildingMixes, shownProgress < 0.97 {
            advanceProgress(to: min(0.97, shownProgress + 0.01), duration: 0.6)
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
    }

    /// Preparation is a first-run state, not a loading state. A returning
    /// listener has a library on disk, and the moment before it is read is not
    /// a reason to show them the first-run screen.
    private var showsPreparationSection: Bool {
        (!libraryStore.hasCachedLibrary && !hasEverSynced) || isBuildingMixes
    }

    /// How many covers have earned their place, given how far the sync has got.
    /// Once the catalogue is in, the wall stands complete while the mixes build.
    private func revealedCoverCount(of total: Int) -> Int {
        guard !libraryStore.hasCachedLibrary else { return total }
        let progress = libraryStore.syncProgress ?? 0
        return Int((Double(total) * progress).rounded())
    }

    private func coverTile(for album: Album, state: CoverTileState) -> some View {
        let isPlaying = playingAlbumID == album.id
        let hasLanded = state == .landed

        return Button {
            togglePlayback(of: album)
        } label: {
            // The cell decides the size and the artwork is cropped into it.
            // Sleeves are not reliably square, and letting one size its own
            // tile puts a hole in the grid.
            Color.appMidBackground
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    // Artwork belongs to a cover that has arrived. The one on
                    // its way is only a shape, which also keeps its image off
                    // the wire until the sync has actually reached it.
                    if hasLanded, let artworkURL = album.artworkURL, let url = URL(string: artworkURL) {
                        CachedAsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image.artworkRendering().scaledToFill()
                            default:
                                Color.appMidBackground
                            }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                // The tile is the only control there is, so the one that is
                // playing has to be legible as such.
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.appAccent, lineWidth: isPlaying ? 2 : 0)
                }
                .brightness(isPlaying || !hasLanded ? 0 : -0.12)
                .blur(radius: state.blur)
                .opacity(state.opacity)
                .scaleEffect(state.scale)
        }
        .buttonStyle(.plain)
        .disabled(!hasLanded)
        .accessibilityLabel(isPlaying ? "Stop \(album.name)" : "Play \(album.name)")
        .accessibilityHidden(!hasLanded)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: state)
        .animation(.easeOut(duration: 0.2), value: isPlaying)
    }

    /// The wall doubles as something to listen to while the library builds.
    /// Tapping a cover plays that album; tapping it again stops.
    private func togglePlayback(of album: Album) {
        guard playingAlbumID != album.id else {
            playerManager.pause()
            playingAlbumID = nil
            return
        }

        playingAlbumID = album.id
        Task {
            let tracks = await JellyfinService.shared.fetchAlbumTracks(albumId: album.id)
            // A second tap, or another cover, while the tracks were on their way.
            guard playingAlbumID == album.id else { return }
            guard !tracks.isEmpty else {
                playingAlbumID = nil
                return
            }
            playerManager.play(tracks: tracks)
        }
    }

    private func loadLibraryPreview() async {
        if previewAlbums.isEmpty {
            let albums = await JellyfinService.shared.fetchPreviewAlbums()
            guard !Task.isCancelled else { return }
            previewAlbums = albums
        }

        // A wall that flashes past is worse than no wall, so it only opens
        // while there is still a sync worth watching. Deciding that from
        // progress rather than a timer keeps it out of the hands of task
        // cancellation: Discover swaps branches the moment Recently Played
        // arrives, which tears down whatever is waiting here.
        guard !previewAlbums.isEmpty, !showsCoverWall else { return }
        guard (libraryStore.syncProgress ?? 0) < 0.85 else { return }

        withAnimation(.easeOut(duration: 0.6)) {
            showsCoverWall = true
        }
    }

    private var libraryPreparationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            // The percentage sits with the title rather than under the bar:
            // one line saying what is happening and how far along it is.
            // One message for the whole wait. Which internal stage is running
            // is not something the listener has any way to care about.
            HStack(alignment: .firstTextBaseline) {
                Label("Preparing your library", systemImage: "sparkles")
                    .font(.appHeadline)
                    .foregroundColor(.appText)

                Spacer()

                if libraryStore.errorMessage == nil {
                    Text("\(Int(preparationProgress * 100))%")
                        .font(.appMono)
                        .foregroundColor(.appTextMuted)
                        .monospacedDigit()
                        // Animating a number means blending two renderings of
                        // the text, which comes out as ghosting. The figure
                        // steps; only the bar glides.
                        .animation(nil, value: shownProgress)
                }
            }

            // Only a failure is worth words. The bar already says it is
            // working, and the name of the current stage is not something
            // anyone can act on.
            if let errorMessage = libraryStore.errorMessage {
                Text(errorMessage)
                    .font(.appBody)
                    .foregroundColor(.appTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // One determinate bar for the whole wait. Swapping in a spinner
            // whenever a stage has no figure to report left a gap where the
            // bar had been.
            if libraryStore.errorMessage == nil {
                ProgressView(value: preparationProgress)
                    .tint(.appAccent)
            }

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
        Button {
            showsDiscoveryErrorDetails = true
        } label: {
            HStack(spacing: 6) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .multilineTextAlignment(.leading)
                if viewModel.errorDetails != nil {
                    Image(systemName: "info.circle")
                        .accessibilityHidden(true)
                }
            }
            .font(.appCaption)
            .foregroundColor(.appTextSecondary)
            .padding(.horizontal, 20)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows details about the refresh failure")
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

    private func startRecentPlayback(_ item: RecentPlayItem) {
        guard let albumID = item.albumID else {
            let index = viewModel.recentTracks.firstIndex { $0.id == item.resumeTrack.id } ?? 0
            startPlayback(viewModel.recentTracks, startingAt: index)
            return
        }

        Task {
            guard let scope = JellyfinService.shared.libraryScope else { return }
            do {
                let albumTracks = try await LibraryRepository.shared.tracks(inAlbum: albumID, in: scope)
                guard !albumTracks.isEmpty else {
                    startPlayback(item.tracks, startingAt: 0)
                    return
                }
                let resumeIndex = albumTracks.firstIndex { $0.id == item.resumeTrack.id } ?? 0
                startPlayback(albumTracks, startingAt: resumeIndex)
            } catch {
                playerManager.errorMessage = "Unable to load \(item.title): \(error.localizedDescription)"
            }
        }
    }
}

private struct DiscoveryMixCard: View {
    let shelf: DiscoveryShelf

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AnimatedArtworkView(url: shelf.seed.artworkURL.flatMap(URL.init(string:))) {
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
            AnimatedArtworkView(url: track.artworkURL.flatMap(URL.init(string:))) {
                ZStack {
                    Color.appElevated
                    Image(systemName: "music.note")
                        .font(.title)
                        .foregroundColor(.appTextMuted)
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

private struct RecentPlayCard: View {
    let item: RecentPlayItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AnimatedArtworkView(url: item.resumeTrack.artworkURL.flatMap(URL.init(string:))) {
                ZStack {
                    Color.appElevated
                    Image(systemName: item.isAlbumSession ? "square.stack" : "music.note")
                        .font(.title)
                        .foregroundColor(.appTextMuted)
                }
            }
            .frame(width: 150, height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.appControlFill))

            Text(item.title)
                .font(.appSubheadline)
                .foregroundColor(.appText)
                .lineLimit(1)
            Text(item.subtitle)
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
