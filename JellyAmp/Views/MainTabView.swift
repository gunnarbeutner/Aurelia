//
//  MainTabView.swift
//  JellyAmp
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
    @State private var libraryPath = NavigationPath()
    @ObservedObject var playerManager = PlayerManager.shared
    @ObservedObject var themeManager = ThemeManager.shared
    @ObservedObject var navCoordinator = NavigationCoordinator.shared
    @ObservedObject var instantMixCoordinator = InstantMixCoordinator.shared

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                NavigationStack {
                    DiscoveryView()
                }
                .tabItem {
                    Label("Discover", systemImage: "sparkles")
                }
                .tag(0)

                NavigationStack(path: $libraryPath) {
                    LibraryView()
                }
                .tabItem {
                    Label("Library", systemImage: "music.note.list")
                }
                .tag(1)
                
                NavigationStack {
                    SearchView()
                }
                .tabItem {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .tag(2)
                
                NavigationStack {
                    FavoritesView(isActive: selectedTab == 3)
                }
                .tabItem {
                    Label("Favorites", systemImage: "heart.fill")
                }
                .tag(3)
                
                NavigationStack {
                    SettingsView()
                }
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .tag(4)
            }
            .tint(.jellyAmpAccent)
            #if targetEnvironment(macCatalyst)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if playerManager.currentTrack != nil {
                    MiniPlayerView(showNowPlaying: $showNowPlaying)
                        .padding(.horizontal, 8)
                        .padding(.top, 8)
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
                        .allowsHitTesting(!showNowPlaying)
                        .accessibilityHidden(showNowPlaying)
                }
            }
            #endif
            
            // Keep the player mounted and animate one intact layer. Conditional
            // removal transitions can leave a departing layer intercepting taps.
            if playerManager.currentTrack != nil {
                GeometryReader { geometry in
                    SwipeToDismissPlayer(
                        isPresented: showNowPlaying,
                        hiddenOffset: geometry.size.height + geometry.safeAreaInsets.bottom,
                        onDismiss: dismissNowPlaying
                    ) { isDismissGestureActive in
                        NowPlayingView(
                            onDismiss: dismissNowPlaying,
                            isDismissGestureActive: isDismissGestureActive
                        )
                    }
                }
                .allowsHitTesting(showNowPlaying)
                .accessibilityHidden(!showNowPlaying)
                .zIndex(1)
            }

            if instantMixCoordinator.isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(.neonCyan)
                    Text("Creating Instant Mix…")
                        .font(.jellyAmpCaption)
                        .foregroundColor(.jellyAmpText)
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
    }

    private func dismissNowPlaying() {
        guard showNowPlaying else { return }
        withAnimation(PlayerPresentationMotion.animation) {
            showNowPlaying = false
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
    let isPresented: Bool
    let hiddenOffset: CGFloat
    let onDismiss: () -> Void
    @ViewBuilder let content: (Bool) -> Content
    @State private var dragOffset: CGFloat = 0
    @State private var isDismissGestureActive = false

    var body: some View {
        content(isDismissGestureActive)
            .offset(y: isPresented ? dragOffset : hiddenOffset)
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        dragOffset = PlayerDismissalInteraction.offset(
                            for: value.translation
                        )
                        isDismissGestureActive = dragOffset > 0
                    }
                    .onEnded { value in
                        isDismissGestureActive = false

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
            .onChange(of: isPresented) { _, _ in
                dragOffset = 0
                isDismissGestureActive = false
            }
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
