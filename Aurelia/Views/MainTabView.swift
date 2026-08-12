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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedTab = 0
    @State private var showNowPlaying = false
    @State private var searchFocusRequest = 0
    @State private var discoverPath = NavigationPath()
    @State private var libraryPath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @State private var favoritesPath = NavigationPath()
    @State private var settingsPath = NavigationPath()
    @ObservedObject var playerManager = PlayerManager.shared
    @ObservedObject var navCoordinator = NavigationCoordinator.shared
    @ObservedObject var instantMixCoordinator = InstantMixCoordinator.shared

    var body: some View {
        ZStack {
            #if targetEnvironment(macCatalyst)
            if showNowPlaying, playerManager.currentTrack != nil {
                catalystPlayerPresentation
                    .transition(.move(edge: .bottom))
            } else {
                tabInterface
                    .transition(.identity)
            }
            #else
            tabInterface
            #endif

            if instantMixCoordinator.isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(.appAccent)
                    Text("Creating Instant Mix…")
                        .font(.appCaption)
                        .foregroundColor(.appText)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.appAccent.opacity(0.35)))
                .allowsHitTesting(false)
                .zIndex(2)
            }
        }
        .alert("Instant Mix", isPresented: instantMixErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(instantMixCoordinator.errorMessage ?? "Unable to create an Instant Mix.")
        }
        .onChange(of: navCoordinator.pendingArtistNavigation) { _, artist in
            guard let artist = artist else { return }
            navCoordinator.pendingArtistNavigation = nil
            selectedTab = 1
            libraryPath = NavigationPath()
            // Stage the push on the next run loop so the tab selection and path
            // reset commit first, without imposing a visible fixed delay.
            DispatchQueue.main.async {
                libraryPath.append(artist)
            }
        }
        .onChange(of: navCoordinator.pendingAlbumNavigation) { _, album in
            guard let album = album else { return }
            navCoordinator.pendingAlbumNavigation = nil
            selectedTab = 1
            libraryPath = NavigationPath()
            DispatchQueue.main.async {
                libraryPath.append(album)
            }
        }
        .onChange(of: navCoordinator.pendingPlayerPresentation) { _, request in
            guard let request else { return }
            navCoordinator.pendingPlayerPresentation = nil
            guard playerManager.currentTrack != nil else { return }
            // Applied without animation: a scripted caller should find the
            // player settled by the time the command returns, rather than
            // racing the presentation spring.
            showNowPlaying = request
        }
        .onChange(of: showNowPlaying) { _, presented in
            navCoordinator.isPlayerPresented = presented
        }
        .onChange(of: navCoordinator.pendingTabSelection) { _, tab in
            guard let tab else { return }
            navCoordinator.pendingTabSelection = nil
            if showNowPlaying { dismissNowPlaying() }
            selectedTab = tab
        }
        .onChange(of: libraryPath) { _, path in
            navCoordinator.libraryNavigationDepth = path.count
        }
        .onAppear {
            navCoordinator.isPlayerPresented = showNowPlaying
        }
        .focusedSceneValue(\.appCommandActions, commandActions)
    }

    private var tabInterface: some View {
        TabView(selection: tabSelection) {
            tabContent(for: 0) {
                NavigationStack(path: $discoverPath) {
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
                NavigationStack(path: $searchPath) {
                    SearchView(searchFocusRequest: searchFocusRequest)
                }
            }
            .tabItem {
                Label("Search", systemImage: "magnifyingglass")
            }
            .tag(2)

            tabContent(for: 3) {
                NavigationStack(path: $favoritesPath) {
                    FavoritesView(isActive: selectedTab == 3)
                }
            }
            .tabItem {
                Label("Favorites", systemImage: "heart.fill")
            }
            .tag(3)

            tabContent(for: 4) {
                NavigationStack(path: $settingsPath) {
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
            }
        }
        #else
        .overlay(alignment: .bottom) {
            // Mini Player floats above the iOS tab bar.
            if playerManager.currentTrack != nil {
                MiniPlayerView(showNowPlaying: $showNowPlaying)
                    .padding(.horizontal, usesBottomTabBar ? 8 : 0)
                    .padding(.bottom, usesBottomTabBar ? MiniPlayerLayout.tabBarClearance : 0)
                    .background {
                        if !usesBottomTabBar {
                            // Ignoring the safe area on the mini-player did not
                            // enlarge its bounds, so iPadOS still exposed a
                            // strip below it. Extend the surface itself while
                            // leaving the controls above the home indicator.
                            Color.appMidBackground.opacity(0.92)
                                .background(.ultraThinMaterial)
                                .ignoresSafeArea(.container, edges: .bottom)
                        }
                    }
                    .opacity(showNowPlaying ? 0 : 1)
                    .allowsHitTesting(!showNowPlaying)
                    .accessibilityHidden(showNowPlaying)
            }
        }
        #endif
    }

    private var tabSelection: Binding<Int> {
        Binding(
            get: { selectedTab },
            set: { tab in
                let changedTab = tab != selectedTab
                selectedTab = tab

                guard showNowPlaying else { return }
                if changedTab {
                    // Let native TabView commit the new selection before the
                    // player layer is removed. Catalyst otherwise restores
                    // focus to the first tab.
                    DispatchQueue.main.async {
                        dismissNowPlaying()
                    }
                } else {
                    // Re-tapping the selected tab has no value change, but the
                    // binding still receives the native selection event.
                    dismissNowPlaying()
                }
            }
        )
    }

    private var usesBottomTabBar: Bool {
        horizontalSizeClass == .compact
    }

    #if targetEnvironment(macCatalyst)
    private var catalystPlayerPresentation: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                NowPlayingView(
                    onDismiss: dismissNowPlaying,
                    embedsAirPlayButton: false
                )

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
        }
    }
    #endif

    private var commandActions: AureliaCommandActions {
        AureliaCommandActions(
            selectedTab: selectedTab,
            isPlayerPresented: showNowPlaying,
            canNavigateBack: showNowPlaying || selectedNavigationDepth > 0,
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
                // Taking first responder in the same turn as the selection
                // change beats Catalyst to committing the tab, which leaves the
                // window chrome describing the tab we just left. Let the
                // selection land, then ask for focus.
                DispatchQueue.main.async {
                    searchFocusRequest += 1
                }
            },
            togglePlayer: {
                guard playerManager.currentTrack != nil else { return }
                withAnimation(PlayerPresentationMotion.animation) {
                    showNowPlaying.toggle()
                }
            },
            navigateBack: navigateBack
        )
    }

    private var selectedNavigationDepth: Int {
        switch selectedTab {
        case 0: discoverPath.count
        case 1: libraryPath.count
        case 2: searchPath.count
        case 3: favoritesPath.count
        case 4: settingsPath.count
        default: 0
        }
    }

    private func navigateBack() {
        if showNowPlaying {
            dismissNowPlaying()
            return
        }

        switch selectedTab {
        case 0 where !discoverPath.isEmpty:
            discoverPath.removeLast()
        case 1 where !libraryPath.isEmpty:
            libraryPath.removeLast()
        case 2 where !searchPath.isEmpty:
            searchPath.removeLast()
        case 3 where !favoritesPath.isEmpty:
            favoritesPath.removeLast()
        case 4 where !settingsPath.isEmpty:
            settingsPath.removeLast()
        default:
            break
        }
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
            #if !targetEnvironment(macCatalyst)
            .overlay {
                if selectedTab == tab {
                    playerPresentation
                }
            }
            #endif
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
            .fill(Color.appTextSecondary)
            .frame(width: 38, height: 5)
            .frame(width: 96, height: 28, alignment: .top)
            .padding(.top, 12)
            .contentShape(Rectangle())
            .gesture(
                // Measure in a stationary coordinate space. Measuring inside
                // the layer being offset feeds the movement back into the
                // gesture and makes pointer drags lag and oscillate.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
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
        // Once dismissal begins, incidental sideways movement must not snap
        // the player back to zero. Only upward movement is resisted.
        max(0, translation.height)
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
