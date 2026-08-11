//
//  MainTabView.swift
//  JellyAmp
//
//  Main tab navigation with native TabView and NavigationStack
//

import SwiftUI

struct MainTabView: View {
    @State private var selectedTab = 0
    @State private var showNowPlaying = false
    @State private var libraryPath = NavigationPath()
    @ObservedObject var playerManager = PlayerManager.shared
    @ObservedObject var themeManager = ThemeManager.shared
    @ObservedObject var navCoordinator = NavigationCoordinator.shared
    @ObservedObject var instantMixCoordinator = InstantMixCoordinator.shared
    @Namespace private var playerAnimation

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
                    FavoritesView()
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
                if playerManager.currentTrack != nil && !showNowPlaying {
                    MiniPlayerView(showNowPlaying: $showNowPlaying, namespace: playerAnimation)
                        .padding(.horizontal, 8)
                        .padding(.top, 8)
                }
            }
            #else
            .overlay(alignment: .bottom) {
                // Mini Player floats above the iOS tab bar.
                if playerManager.currentTrack != nil && !showNowPlaying {
                    MiniPlayerView(showNowPlaying: $showNowPlaying, namespace: playerAnimation)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 56)
                }
            }
            #endif
            
            // Now Playing View as overlay with swipe-to-dismiss
            if showNowPlaying {
                NowPlayingDismissWrapper {
                    showNowPlaying = false
                } content: {
                    NowPlayingView(namespace: playerAnimation, onDismiss: {
                        showNowPlaying = false
                    })
                }
                .transition(.move(edge: .bottom))
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
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: showNowPlaying)
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
        .onChange(of: navCoordinator.nowPlayingPresentationRequest) { _, request in
            guard request != nil else { return }
            showNowPlaying = true
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

// MARK: - Swipe-to-Dismiss Wrapper
struct NowPlayingDismissWrapper<Content: View>: View {
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        content()
            .offset(y: max(0, dragOffset))
            .gesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { value in
                        // Only allow downward drag
                        if value.translation.height > 0 {
                            dragOffset = value.translation.height
                        }
                    }
                    .onEnded { value in
                        if value.translation.height > 150 || value.predictedEndTranslation.height > 300 {
                            // Dismiss
                            onDismiss()
                        }
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            dragOffset = 0
                        }
                    }
            )
            .animation(.interactiveSpring(), value: dragOffset)
    }
}

// MARK: - Preview
#Preview {
    MainTabView()
}
