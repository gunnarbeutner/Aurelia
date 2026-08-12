//
//  NowPlayingView.swift
//  Aurelia
//
//  Now Playing screen — redesigned to match PWA layout
//

import SwiftUI
import AVKit

enum NowPlayingLayout {
    static let horizontalPadding: CGFloat = 20
    static let regularHorizontalPadding: CGFloat = 28
    static let regularColumnSpacing: CGFloat = 28
    static let minimumTwoColumnAspectRatio: CGFloat = 1.25
    static let standardPlayerChromeHeight: CGFloat = 350

    static func airPlayTrailingPadding(usesTwoColumns: Bool) -> CGFloat {
        let contentPadding = usesTwoColumns ? regularHorizontalPadding : horizontalPadding
        return contentPadding + 44
    }

    static func contentWidth(for screenWidth: CGFloat) -> CGFloat {
        max(0, screenWidth - horizontalPadding * 2)
    }

    /// Share of the available width the artwork may occupy.
    static let artworkWidthFraction: CGFloat = 0.65
    /// Share of the viewport height the artwork may occupy. The rest of the
    /// column — title, progress, controls — needs the remainder, so this is what
    /// stops a tall narrow window from pushing the controls off screen.
    static let artworkHeightFraction: CGFloat = 0.45

    /// A regular-width window can still use the single-column layout when it is
    /// tall. Giving artwork the phone-sized share in that configuration makes
    /// the queue feel like a second screen rather than part of the player.
    static let regularSingleColumnArtworkWidthFraction: CGFloat = 0.50
    static let regularSingleColumnArtworkHeightFraction: CGFloat = 0.36

    /// Sizes the artwork against both axes so it grows with the window instead
    /// of stopping at a fixed ceiling. Width alone was capped at 320pt, which
    /// left large and split-screen windows with a small square and a lot of
    /// empty vertical space.
    static func artworkSize(forWidth width: CGFloat, height: CGFloat) -> CGFloat {
        let byWidth = width * artworkWidthFraction
        guard height > 0 else { return max(0, byWidth) }
        return max(0, min(byWidth, height * artworkHeightFraction))
    }

    static func singleColumnArtworkSize(
        forWidth width: CGFloat,
        height: CGFloat,
        isCompactWidth: Bool
    ) -> CGFloat {
        guard !isCompactWidth else {
            return artworkSize(forWidth: width, height: height)
        }

        let byWidth = width * regularSingleColumnArtworkWidthFraction
        guard height > 0 else { return max(0, byWidth) }
        return max(0, min(byWidth, height * regularSingleColumnArtworkHeightFraction))
    }

    static func regularColumnWidths(for screenWidth: CGFloat) -> (player: CGFloat, queue: CGFloat) {
        let availableWidth = max(
            0,
            screenWidth - regularHorizontalPadding * 2 - regularColumnSpacing
        )
        let columnWidth = availableWidth / 2
        return (columnWidth, columnWidth)
    }

    static func usesCondensedPlayerColumn(
        columnWidth: CGFloat,
        viewportHeight: CGFloat
    ) -> Bool {
        artworkSize(forWidth: columnWidth, height: viewportHeight)
            + standardPlayerChromeHeight > viewportHeight
    }

    static func condensedArtworkSize(
        columnWidth: CGFloat,
        viewportHeight: CGFloat
    ) -> CGFloat {
        max(0, min(columnWidth * 0.32, viewportHeight * 0.37))
    }

    static func usesTwoColumns(
        isCompactWidth: Bool,
        screenWidth: CGFloat,
        screenHeight: CGFloat
    ) -> Bool {
        guard !isCompactWidth, screenHeight > 0 else { return false }
        return screenWidth / screenHeight >= minimumTwoColumnAspectRatio
    }
}

enum NowPlayingQueueTab: String, CaseIterable, Identifiable {
    case history = "History"
    case upNext = "Up Next"

    var id: Self { self }
}

enum NowPlayingQueueProjection {
    static func visibleHistory(
        _ history: [Track],
        currentTrackID: String?
    ) -> [Track] {
        history.filter { $0.id != currentTrackID }
    }

    static func upNextIndices(currentIndex: Int, queueCount: Int) -> [Int] {
        let start = max(currentIndex + 1, 0)
        guard start < queueCount else { return [] }
        return Array(start..<queueCount)
    }
}

enum UpNextQueueInteraction {
    static let rowStride: CGFloat = 62

    static func moveDestination(from source: Int, onto target: Int) -> Int {
        source < target ? target + 1 : target
    }

    static func hystereticTargetIndex(
        origin: Int,
        current: Int,
        translation: CGFloat,
        lowerBound: Int,
        upperBound: Int
    ) -> Int {
        guard lowerBound <= upperBound else { return current }
        let translatedRows = translation / rowStride
        let threshold: CGFloat = 0.65
        var target = min(max(current, lowerBound), upperBound)

        while target < upperBound,
              translatedRows > CGFloat(target - origin) + threshold {
            target += 1
        }
        while target > lowerBound,
              translatedRows < CGFloat(target - origin) - threshold {
            target -= 1
        }
        return target
    }

    static func visualOffset(
        for index: Int,
        origin: Int,
        target: Int,
        translation: CGFloat
    ) -> CGFloat {
        if index == origin { return translation }
        if origin < target, index > origin, index <= target { return -rowStride }
        if origin > target, index >= target, index < origin { return rowStride }
        return 0
    }

    static func swipeOffset(
        startOffset: CGFloat,
        translation: CGFloat,
        revealWidth: CGFloat
    ) -> CGFloat {
        min(0, max(-revealWidth, startOffset + translation))
    }

    static func settledSwipeOffset(
        startOffset: CGFloat,
        predictedTranslation: CGFloat,
        revealWidth: CGFloat
    ) -> CGFloat {
        let projectedOffset = swipeOffset(
            startOffset: startOffset,
            translation: predictedTranslation,
            revealWidth: revealWidth
        )
        return projectedOffset < -revealWidth / 2 ? -revealWidth : 0
    }
}

struct NowPlayingView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ObservedObject var playerManager = PlayerManager.shared
    @ObservedObject private var playbackProgress = PlayerManager.shared.playbackProgress
    @ObservedObject var jellyfinService = JellyfinService.shared
    @Environment(\.dismiss) var dismiss
    // Slider state removed — using WaveformView now
    @State private var selectedQueueTab: NowPlayingQueueTab = .upNext
    @State private var showClearUpcomingConfirmation = false
    @State private var isFavorite = false
    @State private var showSleepTimer = false
    @State private var dominantColor: Color?
    @State private var artworkImage: Image?
    @State private var draggedQueueEntryID: String?
    @State private var reorderOriginIndex: Int?
    @State private var reorderTargetIndex: Int?
    @State private var reorderTranslation: CGFloat = 0
    @ObservedObject var sleepTimer = SleepTimerManager.shared
    var onDismiss: (() -> Void)?
    var embedsAirPlayButton = true

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Background: blurred album art (PWA style)
                backgroundLayer

                if NowPlayingLayout.usesTwoColumns(
                    isCompactWidth: horizontalSizeClass == .compact,
                    screenWidth: geo.size.width,
                    screenHeight: geo.size.height
                ) {
                    regularContent(in: geo)
                } else {
                    compactContent(in: geo)
                }
            }
        }
        .onChange(of: playerManager.currentTrack) { _, newTrack in
            isFavorite = newTrack?.isFavorite ?? false
            extractDominantColor(for: newTrack)
        }
        .onAppear {
            isFavorite = playerManager.currentTrack?.isFavorite ?? false
            extractDominantColor(for: playerManager.currentTrack)
        }
    }

    private func compactContent(in geometry: GeometryProxy) -> some View {
        let artworkSize = NowPlayingLayout.singleColumnArtworkSize(
            forWidth: geometry.size.width,
            height: geometry.size.height,
            isCompactWidth: horizontalSizeClass == .compact
        )

        return ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                topBar
                    .padding(.top, horizontalSizeClass == .compact ? 20 : 8)

                artworkSection(size: artworkSize)
                .padding(.top, 16)

                trackInfoSection
                    .padding(.top, 20)

                progressSection
                    .padding(.top, 24)

                controlsSection
                    .padding(.top, 20)

                secondaryActionsSection
                    .padding(.top, 16)

                queueSection
                    .padding(.top, 24)

                Spacer().frame(height: 40)
            }
            .frame(width: NowPlayingLayout.contentWidth(for: geometry.size.width))
            .padding(.horizontal, NowPlayingLayout.horizontalPadding)
        }
        .accessibilityIdentifier("now-playing-scroll")
    }

    private func regularContent(in geometry: GeometryProxy) -> some View {
        let columns = NowPlayingLayout.regularColumnWidths(for: geometry.size.width)

        return VStack(spacing: 0) {
            topBar
                .padding(.top, 8)
                .padding(.horizontal, NowPlayingLayout.regularHorizontalPadding)

            HStack(alignment: .top, spacing: NowPlayingLayout.regularColumnSpacing) {
                ScrollView(.vertical, showsIndicators: false) {
                    Group {
                        if NowPlayingLayout.usesCondensedPlayerColumn(
                            columnWidth: columns.player,
                            viewportHeight: geometry.size.height
                        ) {
                            condensedRegularPlayerColumn(
                                width: columns.player,
                                viewportHeight: geometry.size.height
                            )
                        } else {
                            standardRegularPlayerColumn(
                                width: columns.player,
                                viewportHeight: geometry.size.height
                            )
                        }
                    }
                    .frame(width: columns.player)
                }
                .accessibilityIdentifier("now-playing-player-column")

                ScrollView(.vertical, showsIndicators: false) {
                    queueSection
                        .padding(.top, 12)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(width: columns.queue)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.appBorder)
                        .frame(width: 1)
                        .offset(x: -NowPlayingLayout.regularColumnSpacing / 2)
                }
                .accessibilityIdentifier("now-playing-queue-column")
            }
            .padding(.horizontal, NowPlayingLayout.regularHorizontalPadding)
            .padding(.bottom, 20)
        }
    }

    private func standardRegularPlayerColumn(
        width: CGFloat,
        viewportHeight: CGFloat
    ) -> some View {
        VStack(spacing: 0) {
            artworkSection(screenWidth: width, screenHeight: viewportHeight)
                // The artwork shadow extends above the image. Keep it inside
                // the scroll viewport so Catalyst does not clip its top edge.
                .padding(.top, 32)

            trackInfoSection
                .padding(.top, 20)

            progressSection
                .padding(.top, 24)

            controlsSection
                .padding(.top, 20)

            secondaryActionsSection
                .padding(.top, 16)

            Spacer().frame(height: 24)
        }
    }

    private func condensedRegularPlayerColumn(
        width: CGFloat,
        viewportHeight: CGFloat
    ) -> some View {
        let artSize = NowPlayingLayout.condensedArtworkSize(
            columnWidth: width,
            viewportHeight: viewportHeight
        )

        return VStack(spacing: 0) {
            HStack(spacing: 16) {
                artworkSection(size: artSize)

                trackInfoSection
                    .frame(maxWidth: .infinity)
            }
            .padding(.top, 8)

            progressSection
                .padding(.top, 12)

            controlsSection
            .padding(.top, 32)

            secondaryActionsSection
                .padding(.top, 8)

            Spacer().frame(height: 12)
        }
    }

    // MARK: - Background (blurred album art like PWA)
    private var backgroundLayer: some View {
        ZStack {
            Color.appBackground
                .ignoresSafeArea()

            // Blurred album art background
            if let track = playerManager.currentTrack,
               let artworkURLString = track.artworkURL,
               let artworkURL = URL(string: artworkURLString) {
                ViewportBlurredArtwork(url: artworkURL)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.8), value: track.id)
            }

            // Gradient overlay for readability
            LinearGradient(
                colors: [
                    Color.appBackground.opacity(0.5),
                    Color.appBackground.opacity(0.7),
                    Color.appBackground.opacity(0.9)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            // Dominant color tint
            if let dominantColor = dominantColor {
                dominantColor
                    .opacity(0.15)
                    .ignoresSafeArea()
                    .animation(.easeInOut(duration: 0.8), value: self.dominantColor != nil)
            }
        }
    }

    // MARK: - Top Bar
    private var topBar: some View {
        HStack {
            Button {
                if let onDismiss = onDismiss {
                    onDismiss()
                } else {
                    dismiss()
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.body.weight(.medium))
                    .foregroundColor(.appTextSecondary)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close now playing")
            .accessibilityIdentifier("now-playing-close")

            Spacer()

            if embedsAirPlayButton {
                AirPlayButton()
                    .frame(width: 44, height: 44)
            } else {
                Color.clear
                    .frame(width: 44, height: 44)
            }
        }
    }

    // MARK: - Artwork Section (responsive)
    private func artworkSection(screenWidth: CGFloat, screenHeight: CGFloat) -> some View {
        let artSize = NowPlayingLayout.artworkSize(
            forWidth: screenWidth,
            height: screenHeight
        )

        return artworkSection(size: artSize)
    }

    private func artworkSection(size artSize: CGFloat) -> some View {
        ZStack {
            if let track = playerManager.currentTrack,
               let artworkURLString = track.artworkURL,
               let artworkURL = URL(string: artworkURLString) {
                CachedAsyncImage(url: artworkURL) { phase in
                    switch phase {
                    case .empty:
                        placeholderArtwork(size: artSize)
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: artSize, height: artSize)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(Color.appControlFill, lineWidth: 1)
                            )
                            .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
                    case .failure:
                        placeholderArtwork(size: artSize)
                    @unknown default:
                        placeholderArtwork(size: artSize)
                    }
                }
                .frame(width: artSize, height: artSize)
            } else {
                placeholderArtwork(size: artSize)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Now playing artwork")
        .accessibilityIdentifier("now-playing-artwork")
    }

    private func placeholderArtwork(size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.appMidBackground)
                .frame(width: size, height: size)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.appControlFill, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.5), radius: 20, y: 10)

            Image(systemName: "music.note")
                .font(.largeTitle)
                .foregroundColor(.appTextMuted)
        }
    }

    // MARK: - Track Info Section (with inline favorite — matches PWA)
    private var trackInfoSection: some View {
        HStack(alignment: .top, spacing: 0) {
            // Balance the trailing action so track information remains centered.
            Color.clear
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)

            VStack(alignment: .center, spacing: 6) {
                if let track = playerManager.currentTrack {
                    Text(track.name)
                        .font(.title3.weight(.bold))
                        .foregroundColor(Color.appText)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("now-playing-title")

                    Button {
                        navigateToArtist(track: track)
                    } label: {
                        Text(track.artistName)
                            .font(.subheadline)
                            .foregroundColor(.appTextSecondary)
                            .multilineTextAlignment(.center)
                    }

                    Button {
                        navigateToAlbum(track: track)
                    } label: {
                        Text(track.albumNameWithYear)
                            .font(.caption)
                            .foregroundColor(.appTextMuted)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                } else {
                    Text("No Track Playing")
                        .font(.title3.weight(.bold))
                        .foregroundColor(.appTextSecondary)
                }
            }
            .frame(maxWidth: .infinity)

            Button {
                toggleFavorite()
            } label: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .font(.title3)
                    .foregroundColor(isFavorite ? .appSecondary : .appTextMuted)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(isFavorite ? "Remove from favorites" : "Add to favorites")
            .accessibilityIdentifier("now-playing-favorite")
        }
    }

    // MARK: - Progress Section (Waveform)
    private var progressSection: some View {
        VStack(spacing: 6) {
            WaveformView(
                currentTime: playbackProgress.currentTime,
                duration: playerManager.duration,
                trackId: playerManager.currentTrack?.id ?? "none",
                onSeek: { time in
                    playerManager.seek(to: time)
                }
            )
            .frame(height: 32)
            .accessibilityLabel("Track progress")
            .accessibilityIdentifier("now-playing-waveform")

            HStack {
                Text(formatTime(playbackProgress.currentTime))
                    .font(.appMono)
                    .foregroundColor(.appTextSecondary)
                Spacer()
                Text(formatTime(playerManager.duration))
                    .font(.appMono)
                    .foregroundColor(.appTextSecondary)
            }
        }
    }

    // MARK: - Controls (PWA layout: shuffle | prev | play | next | repeat)
    private var controlsSection: some View {
        HStack(spacing: 0) {
            // Shuffle
            Button {
                playerManager.toggleShuffle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.body)
                    .foregroundColor(playerManager.shuffleEnabled ? .appAccent : .appTextSecondary)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Shuffle")

            Spacer()

            // Previous
            Button {
                playerManager.playPrevious()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title2)
                    .foregroundColor(.appText)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Previous track")

            Spacer()

            // Play/Pause — white circle (PWA style)
            Button {
                playerManager.togglePlayPause()
            } label: {
                ZStack {
                    Circle()
                        .fill(.white)
                        .frame(width: 68, height: 68)
                        .shadow(color: .white.opacity(0.15), radius: 20)

                    Image(systemName: playerManager.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .foregroundColor(.black)
                        .offset(x: playerManager.isPlaying ? 0 : 2)
                }
            }
            .accessibilityLabel(playerManager.isPlaying ? "Pause" : "Play")

            Spacer()

            // Next
            Button {
                playerManager.playNext()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title2)
                    .foregroundColor(.appText)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Next track")

            Spacer()

            // Repeat
            Button {
                playerManager.toggleRepeatMode()
            } label: {
                Image(systemName: repeatIcon)
                    .font(.body)
                    .foregroundColor(playerManager.repeatMode != .off ? .appAccent : .appTextSecondary)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Repeat")
        }
    }

    var repeatIcon: String {
        switch playerManager.repeatMode {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    // MARK: - Secondary Actions
    private var secondaryActionsSection: some View {
        HStack(spacing: 12) {
            // Playback Speed
            Button {
                playerManager.cyclePlaybackRate()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "speedometer")
                        .font(.caption)
                    Text(playerManager.playbackRate == 1.0 ? "1x" : String(format: "%.2gx", playerManager.playbackRate))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                }
                .foregroundColor(playerManager.playbackRate != 1.0 ? .appAccent : .appTextSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(playerManager.playbackRate != 1.0 ? Color.appAccent.opacity(0.15) : Color.appControlFill)
                )
                .overlay(
                    Capsule()
                        .stroke(playerManager.playbackRate != 1.0 ? Color.appAccent.opacity(0.3) : Color.clear, lineWidth: 1)
                )
            }
            .accessibilityLabel("Playback speed: \(playerManager.playbackRate)x")

            // Sleep Timer
            Button {
                showSleepTimer = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "moon.zzz")
                        .font(.caption)
                    if sleepTimer.isActive {
                        Text(sleepTimer.formattedRemaining)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                    }
                }
                .foregroundColor(sleepTimer.isActive ? .appAccent : .appTextSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(sleepTimer.isActive ? Color.appAccent.opacity(0.15) : Color.appControlFill)
                )
                .overlay(
                    Capsule()
                        .stroke(sleepTimer.isActive ? Color.appAccent.opacity(0.3) : Color.clear, lineWidth: 1)
                )
            }
            .confirmationDialog("Sleep Timer", isPresented: $showSleepTimer, titleVisibility: .visible) {
                ForEach(SleepTimerOption.allCases) { option in
                    Button(option.rawValue) {
                        sleepTimer.start(option: option)
                    }
                }
                if sleepTimer.isActive {
                    Button("Cancel Timer", role: .destructive) {
                        sleepTimer.cancel()
                    }
                }
            } message: {
                if sleepTimer.isActive {
                    Text("Timer active: \(sleepTimer.formattedRemaining)")
                } else {
                    Text("Pause playback after...")
                }
            }
        }
    }

    // MARK: - Queue Section
    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            queueTabPicker

            switch selectedQueueTab {
            case .history:
                historyQueueContent
            case .upNext:
                upNextQueueContent
            }
        }
        .coordinateSpace(name: UpNextQueueRow.coordinateSpaceName)
        .confirmationDialog(
            "Clear Up Next?",
            isPresented: $showClearUpcomingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear Up Next", role: .destructive) {
                playerManager.clearUpcomingQueue()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The current song and listening history will be kept.")
        }
    }

    private var queueTabPicker: some View {
        HStack(spacing: 0) {
            ForEach(NowPlayingQueueTab.allCases) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        selectedQueueTab = tab
                    }
                } label: {
                    Text(tab.rawValue)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(
                            selectedQueueTab == tab
                                ? Color.appText
                                : Color.appTextSecondary
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                        .background {
                            if selectedQueueTab == tab {
                                Capsule().fill(Color.appControlFill)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedQueueTab == tab ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.appControlFill))
        .overlay(Capsule().stroke(Color.appBorder, lineWidth: 1))
        .accessibilityIdentifier("now-playing-queue-tabs")
    }

    @ViewBuilder
    private var historyQueueContent: some View {
        let tracks = NowPlayingQueueProjection.visibleHistory(
            playerManager.playbackHistory,
            currentTrackID: playerManager.currentTrack?.id
        )

        if tracks.isEmpty {
            queueEmptyState(
                icon: "clock.arrow.circlepath",
                title: "No listening history",
                message: "Tracks you finish will appear here."
            )
        } else {
            LazyVStack(spacing: 10) {
                ForEach(tracks, id: \.id) { track in
                    HistoryQueueRow(track: track) {
                        playerManager.playFromHistory(track)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var upNextQueueContent: some View {
        let entries = nextTrackEntries()

        if entries.isEmpty {
            queueEmptyState(
                icon: "text.line.last.and.arrowtriangle.forward",
                title: "Nothing up next",
                message: "Add or play more music to extend the queue."
            )
        } else {
            HStack {
                Text("\(entries.count) track\(entries.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(.appTextSecondary)

                Spacer()

                Button("Clear") {
                    showClearUpcomingConfirmation = true
                }
                .font(.caption.weight(.semibold))
                .foregroundColor(.appSecondary)
                .buttonStyle(.plain)
                .accessibilityLabel("Clear Up Next")
            }
            .padding(.horizontal, 4)

            LazyVStack(spacing: 10) {
                ForEach(entries) { entry in
                    UpNextQueueRow(
                        track: entry.track,
                        verticalOffset: queueRowOffset(for: entry),
                        isBeingReordered: draggedQueueEntryID == entry.id,
                        isQueueReordering: draggedQueueEntryID != nil,
                        onPlay: {
                            playerManager.jumpToTrack(at: entry.index)
                        },
                        onDelete: {
                            playerManager.removeFromQueue(at: entry.index)
                        },
                        onReorder: { translation, ended in
                            reorderUpNext(
                                initialIndex: entry.index,
                                entryID: entry.id,
                                translation: translation,
                                ended: ended,
                                upperBound: entries.last?.index ?? entry.index
                            )
                        }
                    )
                }
            }
        }
    }

    private func queueEmptyState(
        icon: String,
        title: String,
        message: String
    ) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.appTextMuted)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.appTextSecondary)
            Text(message)
                .font(.caption)
                .foregroundColor(.appTextMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private func nextTrackEntries() -> [QueueTrackEntry] {
        NowPlayingQueueProjection.upNextIndices(
            currentIndex: playerManager.currentIndex,
            queueCount: playerManager.queue.count
        ).map {
            QueueTrackEntry(index: $0, track: playerManager.queue[$0])
        }
    }

    private func reorderUpNext(
        initialIndex: Int,
        entryID: String,
        translation: CGFloat,
        ended: Bool,
        upperBound: Int
    ) {
        if reorderOriginIndex == nil {
            reorderOriginIndex = initialIndex
            reorderTargetIndex = initialIndex
            draggedQueueEntryID = entryID
        }

        guard draggedQueueEntryID == entryID,
              let origin = reorderOriginIndex else { return }
        let currentTarget = reorderTargetIndex ?? origin
        let target = UpNextQueueInteraction.hystereticTargetIndex(
            origin: origin,
            current: currentTarget,
            translation: translation,
            lowerBound: playerManager.currentIndex + 1,
            upperBound: upperBound
        )
        reorderTranslation = translation
        reorderTargetIndex = target

        guard ended else { return }

        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            if target != origin {
                playerManager.moveInQueue(
                    from: origin,
                    to: UpNextQueueInteraction.moveDestination(from: origin, onto: target)
                )
            }
            reorderOriginIndex = nil
            reorderTargetIndex = nil
            reorderTranslation = 0
            draggedQueueEntryID = nil
        }
    }

    private func queueRowOffset(for entry: QueueTrackEntry) -> CGFloat {
        guard let origin = reorderOriginIndex,
              let target = reorderTargetIndex else { return 0 }
        return UpNextQueueInteraction.visualOffset(
            for: entry.index,
            origin: origin,
            target: target,
            translation: reorderTranslation
        )
    }

    // MARK: - Dominant Color Extraction
    private func extractDominantColor(for track: Track?) {
        guard let track = track,
              let urlString = track.artworkURL,
              let url = URL(string: urlString) else {
            dominantColor = nil
            return
        }

        Task {
            if let cachedImage = await ImageCache.shared.cachedImage(for: url) {
                let color = await DominantColorExtractor.shared.dominantColor(from: cachedImage, trackId: track.id)
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.8)) {
                        dominantColor = color
                    }
                }
            } else if let img = try? await ImageCache.shared.loadImage(from: url) {
                let color = await DominantColorExtractor.shared.dominantColor(from: img, trackId: track.id)
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.8)) {
                        dominantColor = color
                    }
                }
            }
        }
    }

    // MARK: - Helpers
    private func formatTime(_ time: TimeInterval) -> String {
        guard !time.isNaN && !time.isInfinite && time >= 0 else { return "0:00" }
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func navigateToArtist(track: Track) {
        NavigationCoordinator.shared.navigateToArtist(for: track)
        if let onDismiss = onDismiss { onDismiss() } else { dismiss() }
    }

    private func navigateToAlbum(track: Track) {
        NavigationCoordinator.shared.navigateToAlbum(for: track)
        if let onDismiss = onDismiss { onDismiss() } else { dismiss() }
    }

    private func toggleFavorite() {
        guard let currentTrack = playerManager.currentTrack else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        withAnimation(.spring(response: 0.3)) {
            isFavorite.toggle()
        }
        let updatedFavoriteValue = isFavorite

        Task {
            do {
                if updatedFavoriteValue {
                    try await jellyfinService.markFavorite(itemId: currentTrack.id)
                } else {
                    try await jellyfinService.unmarkFavorite(itemId: currentTrack.id)
                }
                let currentIndex = playerManager.currentIndex
                if currentIndex < playerManager.queue.count {
                    playerManager.queue[currentIndex].isFavorite = updatedFavoriteValue
                }
                FavoriteMutationCenter.shared.publish(
                    .track(currentTrack, isFavorite: updatedFavoriteValue)
                )
            } catch {
                await MainActor.run {
                    withAnimation(.spring(response: 0.3)) {
                        isFavorite.toggle()
                    }
                }
            }
        }
    }
}

private struct QueueTrackEntry: Identifiable {
    let index: Int
    let track: Track

    var id: String { "\(index):\(track.id)" }
}

private struct HistoryQueueRow: View {
    let track: Track
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 12) {
                CachedAsyncImage(url: URL(string: track.artworkURL ?? "")) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        Rectangle().fill(Color.appMidBackground)
                            .overlay(
                                Image(systemName: "music.note")
                                    .font(.caption)
                                    .foregroundColor(.appTextMuted)
                            )
                    }
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.appControlFill, lineWidth: 1)
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.appTextSecondary)
                        .lineLimit(1)
                    Text(track.artistName)
                        .font(.caption)
                        .foregroundColor(.appTextMuted)
                        .lineLimit(1)
                }

                Spacer()

                Text(track.durationFormatted)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.appTextMuted)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.appBackground.opacity(0.001))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play \(track.name) again")
        .accessibilityIdentifier("now-playing-history-\(track.id)")
        .contextMenu {
            TrackContextMenu(track: track)
        }
    }
}

private struct UpNextQueueRow: View {
    static let coordinateSpaceName = "now-playing-up-next-queue"

    let track: Track
    let verticalOffset: CGFloat
    let isBeingReordered: Bool
    let isQueueReordering: Bool
    let onPlay: () -> Void
    let onDelete: () -> Void
    let onReorder: (_ translation: CGFloat, _ ended: Bool) -> Void
    @State private var swipeOffset: CGFloat = 0
    @State private var swipeStartOffset: CGFloat?
    @State private var swipeAxis: Axis?
    @State private var isReorderGestureActive = false

    private let deleteWidth: CGFloat = 88

    var body: some View {
        ZStack(alignment: .trailing) {
            if swipeOffset < 0, !isQueueReordering, !isReorderGestureActive {
                Button(role: .destructive) {
                    swipeOffset = 0
                    onDelete()
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "trash.fill")
                        Text("Delete")
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundColor(.white)
                    .frame(width: deleteWidth)
                    .frame(maxHeight: .infinity)
                    .background(Color.red.opacity(0.9))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete \(track.name) from queue")
                .zIndex(1)
            }

            HStack(spacing: 0) {
                HStack(spacing: 12) {
                    CachedAsyncImage(url: URL(string: track.artworkURL ?? "")) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().aspectRatio(contentMode: .fill)
                        default:
                            Rectangle().fill(Color.appMidBackground)
                                .overlay(
                                    Image(systemName: "music.note")
                                        .font(.caption)
                                        .foregroundColor(.appTextMuted)
                                )
                        }
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.appControlFill, lineWidth: 1)
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.appTextSecondary)
                            .lineLimit(1)
                        Text(track.artistName)
                            .font(.caption)
                            .foregroundColor(.appTextMuted)
                            .lineLimit(1)
                    }

                    Spacer()

                    Text(track.durationFormatted)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.appTextMuted)
                }
                .padding(.leading, 8)
                .padding(.trailing, 6)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .onTapGesture(perform: onPlay)
                .highPriorityGesture(horizontalSwipe)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Play \(track.name) next")
                .accessibilityIdentifier("now-playing-up-next-\(track.id)")
                .accessibilityAction(named: "Delete") { onDelete() }
                .contextMenu {
                    TrackContextMenu(track: track)
                }

                Image(systemName: "line.3.horizontal")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.appTextMuted)
                    .frame(width: 44, height: 52)
                    .contentShape(Rectangle())
                    .accessibilityLabel("Reorder \(track.name)")
                    .highPriorityGesture(reorderGesture)
            }
            .frame(maxWidth: .infinity)
            .background(Color.appBackground.opacity(0.001))
            .offset(x: swipeOffset)
            .zIndex(0)
        }
        .contentShape(Rectangle())
        .clipped()
        .frame(height: 52)
        .offset(y: verticalOffset)
        .zIndex(isBeingReordered ? 1 : 0)
        .animation(isBeingReordered ? nil : .easeOut(duration: 0.1), value: verticalOffset)
    }

    private var horizontalSwipe: some Gesture {
        DragGesture(
            minimumDistance: 12,
            coordinateSpace: .named(Self.coordinateSpaceName)
        )
            .onChanged { value in
                guard !isQueueReordering,
                      !isReorderGestureActive else { return }
                if swipeAxis == nil {
                    swipeAxis = abs(value.translation.width) > abs(value.translation.height)
                        ? .horizontal
                        : .vertical
                    if swipeAxis == .horizontal {
                        swipeStartOffset = swipeOffset
                    }
                }
                guard swipeAxis == .horizontal,
                      let startOffset = swipeStartOffset else { return }
                swipeOffset = UpNextQueueInteraction.swipeOffset(
                    startOffset: startOffset,
                    translation: value.translation.width,
                    revealWidth: deleteWidth
                )
            }
            .onEnded { value in
                defer {
                    swipeAxis = nil
                    swipeStartOffset = nil
                }
                guard !isQueueReordering,
                      !isReorderGestureActive,
                      swipeAxis == .horizontal,
                      let startOffset = swipeStartOffset else { return }
                let settledOffset = UpNextQueueInteraction.settledSwipeOffset(
                    startOffset: startOffset,
                    predictedTranslation: value.predictedEndTranslation.width,
                    revealWidth: deleteWidth
                )
                withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                    swipeOffset = settledOffset
                }
            }
    }

    private var reorderGesture: some Gesture {
        DragGesture(
            minimumDistance: 4,
            coordinateSpace: .named(Self.coordinateSpaceName)
        )
            .onChanged { value in
                isReorderGestureActive = true
                swipeOffset = 0
                swipeStartOffset = nil
                swipeAxis = nil
                onReorder(value.translation.height, false)
            }
            .onEnded { value in
                onReorder(value.translation.height, true)
                DispatchQueue.main.async {
                    isReorderGestureActive = false
                }
            }
    }
}

// MARK: - AirPlay Button
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let routePickerView = AVRoutePickerView()
        routePickerView.backgroundColor = .clear
        routePickerView.activeTintColor = UIColor(Color.appAccent)
        routePickerView.tintColor = UIColor(.appTextSecondary)
        routePickerView.prioritizesVideoDevices = false
        return routePickerView
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

// MARK: - Preview
#Preview {
    struct PreviewWrapper: View {
        var body: some View {
            NowPlayingView()
        }
    }
    return PreviewWrapper()
}
