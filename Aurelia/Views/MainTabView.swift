//
//  MainTabView.swift
//  Aurelia
//
//  Main tab navigation with native TabView and NavigationStack
//

import SwiftUI

enum PlayerPresentationMotion {
    static let animation = Animation.spring(response: 0.42, dampingFraction: 0.88)
}

struct MainTabView: View {
    @State private var selectedTab = 0
    @State private var showNowPlaying = false
    @State private var searchFocusRequest = 0
    @State private var libraryPath = NavigationPath()
    @ObservedObject var playerManager = PlayerManager.shared
    @ObservedObject var themeManager = ThemeManager.shared
    @ObservedObject var navCoordinator = NavigationCoordinator.shared
    @ObservedObject var instantMixCoordinator = InstantMixCoordinator.shared

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                tabContent(for: 0) {
                    NavigationStack {
                        DiscoveryView()
                    }
                }
                .tabItem {
                    Label("Discover", systemImage: "sparkles")
                }
                .tag(0)

                tabContent(for: 1) {
                    NavigationStack(path: $libraryPath) {
                        LibraryView()
                    }
                }
                .tabItem {
                    Label("Library", systemImage: "music.note.list")
                }
                .tag(1)
                
                tabContent(for: 2) {
                    NavigationStack {
                        SearchView(searchFocusRequest: searchFocusRequest)
                    }
                }
                .tabItem {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .tag(2)
                
                tabContent(for: 3) {
                    NavigationStack {
                        FavoritesView(isActive: selectedTab == 3)
                    }
                }
                .tabItem {
                    Label("Favorites", systemImage: "heart.fill")
                }
                .tag(3)
                
                tabContent(for: 4) {
                    NavigationStack {
                        SettingsView()
                    }
                }
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .tag(4)
            }
            .tint(.appAccent)
            #if targetEnvironment(macCatalyst)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if playerManager.currentTrack != nil {
                    MiniPlayerView(showNowPlaying: $showNowPlaying)
                        .padding(.horizontal, 8)
                        .padding(.top, 8)
                        .opacity(showNowPlaying ? 0 : 1)
                        .allowsHitTesting(!showNowPlaying)
                        .accessibilityHidden(showNowPlaying)
                }
            }
            #else
            .overlay(alignment: .bottom) {
                // Mini Player floats above the iOS tab bar.
                if playerManager.currentTrack != nil {
                    MiniPlayerView(showNowPlaying: $showNowPlaying)
                        .padding(.horizontal, 8)
                        .padding(.bottom, MiniPlayerLayout.tabBarClearance)
                        .opacity(showNowPlaying ? 0 : 1)
                        .allowsHitTesting(!showNowPlaying)
                        .accessibilityHidden(showNowPlaying)
                }
            }
            #endif

            if instantMixCoordinator.isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(.neonCyan)
                    Text("Creating Instant Mix…")
                        .font(.appCaption)
                        .foregroundColor(.appText)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.neonCyan.opacity(0.35)))
                .allowsHitTesting(false)
                .zIndex(2)
            }
        }
        .alert("Instant Mix", isPresented: instantMixErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(instantMixCoordinator.errorMessage ?? "Unable to create an Instant Mix.")
        }
        .onChange(of: selectedTab) { oldTab, newTab in
            guard oldTab != newTab, showNowPlaying else { return }

            // Let the native tab control finish committing its selection before
            // removing the player layer. Mutating the hierarchy inside the tab
            // selection callback makes Catalyst restore focus to the first tab.
            DispatchQueue.main.async {
                dismissNowPlaying()
            }
        }
        .onChange(of: navCoordinator.pendingArtistNavigation) { _, artist in
            guard let artist = artist else { return }
            navCoordinator.pendingArtistNavigation = nil
            selectedTab = 1
            libraryPath = NavigationPath()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                libraryPath.append(artist)
            }
        }
        .onChange(of: navCoordinator.pendingAlbumNavigation) { _, album in
            guard let album = album else { return }
            navCoordinator.pendingAlbumNavigation = nil
            selectedTab = 1
            libraryPath = NavigationPath()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                libraryPath.append(album)
            }
        }
        .focusedSceneValue(\.appCommandActions, commandActions)
    }

    private var commandActions: AureliaCommandActions {
        AureliaCommandActions(
            selectedTab: selectedTab,
            isPlayerPresented: showNowPlaying,
            selectTab: { tab in
                if showNowPlaying {
                    dismissNowPlaying()
                }
                selectedTab = tab
            },
            focusSearch: {
                if showNowPlaying {
                    dismissNowPlaying()
                }
                selectedTab = 2
                searchFocusRequest += 1
            },
            togglePlayer: {
                guard playerManager.currentTrack != nil else { return }
                withAnimation(PlayerPresentationMotion.animation) {
                    showNowPlaying.toggle()
                }
            },
            dismissPlayer: dismissNowPlaying
        )
    }

    private func dismissNowPlaying() {
        guard showNowPlaying else { return }
        withAnimation(PlayerPresentationMotion.animation) {
            showNowPlaying = false
        }
    }

    private func tabContent<Content: View>(
        for tab: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .overlay {
                if selectedTab == tab {
                    playerPresentation
                }
            }
    }

    @ViewBuilder
    private var playerPresentation: some View {
        // Keep the player mounted and animate one intact layer. Constraining it
        // to the selected tab's content leaves the system tab controls usable.
        if playerManager.currentTrack != nil {
            GeometryReader { geometry in
                ZStack(alignment: .topTrailing) {
                    SwipeToDismissPlayer(
                        isPresented: showNowPlaying,
                        hiddenOffset: geometry.size.height + geometry.safeAreaInsets.bottom,
                        onDismiss: dismissNowPlaying
                    ) {
                        #if targetEnvironment(macCatalyst)
                        NowPlayingView(
                            onDismiss: dismissNowPlaying,
                            embedsAirPlayButton: false
                        )
                        #else
                        NowPlayingView(onDismiss: dismissNowPlaying)
                        #endif
                    }

                    #if targetEnvironment(macCatalyst)
                    if showNowPlaying {
                        AirPlayButton()
                            .frame(width: 44, height: 44)
                            .padding(.top, 8)
                            .padding(
                                .trailing,
                                NowPlayingLayout.airPlayTrailingPadding(
                                    usesTwoColumns: NowPlayingLayout.usesTwoColumns(
                                        isCompactWidth: false,
                                        screenWidth: geometry.size.width,
                                        screenHeight: geometry.size.height
                                    )
                                )
                            )
                    }
                    #endif
                }
            }
            .allowsHitTesting(showNowPlaying)
            .accessibilityHidden(!showNowPlaying)
        }
    }

    private var instantMixErrorBinding: Binding<Bool> {
        Binding(
            get: { instantMixCoordinator.errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    instantMixCoordinator.errorMessage = nil
                }
            }
        )
    }
}

struct SwipeToDismissPlayer<Content: View>: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let isPresented: Bool
    let hiddenOffset: CGFloat
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .top) {
            content()

            if horizontalSizeClass == .compact {
                dismissHandle
            }
        }
            .offset(y: isPresented ? dragOffset : hiddenOffset)
            .onChange(of: isPresented) { _, _ in
                dragOffset = 0
            }
    }

    private var dismissHandle: some View {
        Capsule()
            .fill(Color.white.opacity(0.45))
            .frame(width: 38, height: 5)
            .frame(width: 96, height: 28, alignment: .top)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        dragOffset = PlayerDismissalInteraction.offset(
                            for: value.translation
                        )
                    }
                    .onEnded { value in
                        if PlayerDismissalInteraction.shouldDismiss(
                            translation: value.translation,
                            predictedEndTranslation: value.predictedEndTranslation
                        ) {
                            onDismiss()
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                                dragOffset = 0
                            }
                        }
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("Dismiss now playing")
            .accessibilityHint("Swipe down to close the player")
            .accessibilityIdentifier("now-playing-dismiss-handle")
    }
}

enum PlayerDismissalInteraction {
    static func offset(for translation: CGSize) -> CGFloat {
        let isDownward = translation.height > 0
        let isVertical = abs(translation.height) > abs(translation.width)
        return isDownward && isVertical ? translation.height : 0
    }

    static func shouldDismiss(
        translation: CGSize,
        predictedEndTranslation: CGSize
    ) -> Bool {
        translation.height > 150 || predictedEndTranslation.height > 300
    }
}

// MARK: - Preview
#Preview {
    MainTabView()
}
