//
//  SearchView.swift
//  JellyAmp
//
//  Search across artists, albums, and tracks - Cypherpunk theme
//

import SwiftUI
import UIKit

struct SearchView: View {
    let searchFocusRequest: Int
    @ObservedObject var themeManager = ThemeManager.shared
    @ObservedObject var playerManager = PlayerManager.shared
    private let repository = LibraryRepository.shared
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dismissSearch) private var dismissSearch

    @State private var searchText = ""
    @State private var searchResults: [LibrarySearchResult] = []
    @State private var isSearching = false
    @State private var selectedFilter: SearchFilter = .all
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var isSearchFieldFocused: Bool
    // Navigation handled by NavigationStack

    init(searchFocusRequest: Int = 0) {
        self.searchFocusRequest = searchFocusRequest
    }

    enum SearchFilter: String, CaseIterable {
        case all = "All"
        case artists = "Artists"
        case albums = "Albums"
        case tracks = "Tracks"
    }

    var body: some View {
        ZStack {
            // Background
            LinearGradient(
                colors: [
                    Color.jellyAmpBackground,
                    Color.jellyAmpMidBackground,
                    Color.jellyAmpBackground
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                #if targetEnvironment(macCatalyst)
                catalystSearchField
                #endif

                // Filter Tabs
                filterTabs

                // Results
                if searchText.isEmpty {
                    emptySearchView
                } else if isSearching {
                    loadingView
                } else if searchResults.isEmpty {
                    noResultsView
                } else {
                    searchResultsList
                }
            }
        }
        #if !targetEnvironment(macCatalyst)
        .searchable(text: $searchText, prompt: "Search artists, albums, tracks...")
        .jellyAmpSearchFocused($isSearchFieldFocused)
        #endif
        .onChange(of: searchText) { _, newValue in
            performSearch(query: newValue)
        }
        .onChange(of: searchFocusRequest) { _, _ in
            focusSearchField()
        }
        .onChange(of: selectedFilter) { _, _ in
            performSearch(query: searchText)
        }
        .navigationDestination(for: Album.self) { album in
            AlbumDetailView(album: album)
        }
        .navigationDestination(for: Artist.self) { artist in
            ArtistDetailView(artist: artist)
        }
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
    }

    #if targetEnvironment(macCatalyst)
    private var catalystSearchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.jellyAmpTextSecondary)

            TextField("Search artists, albums, tracks…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($isSearchFieldFocused)
                .focusEffectDisabled()

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.jellyAmpTextSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(
            Capsule()
                .fill(Color.jellyAmpElevated)
                .overlay(
                    Capsule().stroke(
                        isSearchFieldFocused
                            ? Color.jellyAmpAccent.opacity(0.45)
                            : Color.white.opacity(0.12),
                        lineWidth: 1
                    )
                )
        )
        .frame(maxWidth: 720)
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }
    #endif

    private func focusSearchField() {
        DispatchQueue.main.async {
            isSearchFieldFocused = true
        }
    }

    // MARK: - Filter Tabs
    private var filterTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(SearchFilter.allCases, id: \.self) { filter in
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            selectedFilter = filter
                        }
                    } label: {
                        Text(filter.rawValue)
                            .font(.subheadline.weight(.bold))
                            .foregroundColor(selectedFilter == filter ? .black : .jellyAmpAccent)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background {
                                if selectedFilter == filter {
                                    Capsule().fill(Color.jellyAmpAccent)
                                } else {
                                    Capsule().fill(.ultraThinMaterial)
                                }
                            }
                    }
                    .accessibilityLabel("Filter: \(filter.rawValue)")
                    .accessibilityAddTraits(selectedFilter == filter ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 16)
    }

    // MARK: - Results List
    private var searchResultsList: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(searchResults) { result in
                    switch result {
                    case .artist(let artist):
                        NavigationLink(value: artist) {
                            SearchResultRow(result: result)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("search-result-\(artist.id)")
                        .contextMenu {
                            InstantMixButton(itemId: artist.id, itemName: artist.name)
                        }
                    case .album(let album):
                        NavigationLink(value: album) {
                            SearchResultRow(result: result)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("search-result-\(album.id)")
                        .contextMenu {
                            AlbumContextMenu(album: album)
                        }
                    case .track(let track):
                        Button { handleTrackTap(track) } label: {
                            SearchResultRow(result: result)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("search-result-\(track.id)")
                        .contextMenu {
                            TrackContextMenu(track: track)
                        }
                    }
                }

                Color.clear.frame(height: 20)
            }
            .padding(.top, 8)
        }
        .accessibilityIdentifier("search-results-list")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if playerManager.currentTrack != nil {
                Color.jellyAmpBackground
                    .frame(height: MiniPlayerLayout.contentClearance)
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: - Empty State
    private var emptySearchView: some View {
        ContentUnavailableView {
            Label("Search Your Library", systemImage: "magnifyingglass")
        } description: {
            Text("Find artists, albums, and tracks")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Loading State
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(.jellyAmpAccent)
                .scaleEffect(1.5)

            Text("Searching...")
                .font(.body)
                .foregroundColor(.jellyAmpTextSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - No Results State
    private var noResultsView: some View {
        ContentUnavailableView {
            Label("No Results", systemImage: "music.note.list")
        } description: {
            Text("Try a different search term")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions
    private func performSearch(query: String) {
        guard !query.isEmpty else {
            searchResults = []
            return
        }

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-player-layout") {
            searchTask?.cancel()
            searchResults = Self.uiTestSearchResults
            isSearching = false
            return
        }
        #endif

        // Cancel previous search task to avoid race conditions
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3 seconds
            guard !Task.isCancelled else { return }

            await MainActor.run {
                isSearching = true
            }

            do {
                guard let scope = JellyfinService.shared.libraryScope else {
                    throw JellyfinError.notAuthenticated
                }
                let results = try await repository.search(
                    query,
                    filter: selectedFilter.libraryFilter,
                    in: scope
                )
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    searchResults = results
                    isSearching = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                print("Search error: \(error)")
                await MainActor.run {
                    searchResults = []
                    isSearching = false
                }
            }
        }
    }

    #if DEBUG
    private static var uiTestSearchResults: [LibrarySearchResult] {
        (1...8).map { index in
            .track(Track(
                id: "ui-search-\(index)",
                name: "Search Layout Track \(index)",
                artistName: "Search Layout Artist",
                albumName: "Search Layout Album",
                duration: 180,
                artworkURL: nil,
                albumId: "ui-search-album"
            ))
        }
    }
    #endif

    private func handleTrackTap(_ track: Track) {
        dismissSearch()
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        playerManager.play(tracks: [track])
    }
}

private extension SearchView.SearchFilter {
    var libraryFilter: LibrarySearchFilter {
        switch self {
        case .all: return .all
        case .artists: return .artists
        case .albums: return .albums
        case .tracks: return .tracks
        }
    }
}

private extension View {
    @ViewBuilder
    func jellyAmpSearchFocused(_ focus: FocusState<Bool>.Binding) -> some View {
        if #available(iOS 18.0, macCatalyst 18.0, *) {
            searchFocused(focus)
        } else {
            self
        }
    }
}

// MARK: - Search Result Row
struct SearchResultRow: View {
    let result: LibrarySearchResult

    var body: some View {
        HStack(spacing: 16) {
                // Artwork/Icon
                if let artworkURL, let url = URL(string: artworkURL) {
                    CachedAsyncImage(url: url) { phase in
                        switch phase {
                        case .empty:
                            placeholderImage
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 60, height: 60)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        case .failure:
                            placeholderImage
                        @unknown default:
                            placeholderImage
                        }
                    }
                    .frame(width: 60, height: 60)
                } else {
                    placeholderImage
                }

                // Item Info
                VStack(alignment: .leading, spacing: 6) {
                    Text(name)
                        .font(.body.weight(.semibold))
                        .foregroundColor(Color.jellyAmpText)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        // Type Badge
                        Text(itemTypeLabel)
                            .font(.caption.weight(.bold))
                            .foregroundColor(itemTypeColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(itemTypeColor.opacity(0.2))
                            )

                        // Additional Info based on type
                        if case .artist(let artist) = result {
                            // Show album count for artists
                            let albumCount = artist.albumCount
                            if albumCount > 0 {
                                Text("\(albumCount) album\(albumCount == 1 ? "" : "s")")
                                    .font(.subheadline)
                                    .foregroundColor(.jellyAmpTextSecondary)
                                    .lineLimit(1)
                            }
                        } else if let subtitle {
                            // Show artist name for albums/tracks
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundColor(.jellyAmpTextSecondary)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer()

                // Chevron
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.jellyAmpTextSecondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.jellyAmpMidBackground.opacity(0.3))
            )
            .contentShape(Rectangle())
        .padding(.horizontal, 16)
    }

    private var placeholderImage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    LinearGradient(
                        colors: [Color.jellyAmpAccent.opacity(0.3), Color.jellyAmpTertiary.opacity(0.3)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 60, height: 60)

            Image(systemName: itemTypeIcon)
                .font(.title2)
                .foregroundColor(.white.opacity(0.6))
        }
    }

    private var itemTypeLabel: String {
        switch result {
        case .artist: return "ARTIST"
        case .album: return "ALBUM"
        case .track: return "TRACK"
        }
    }

    private var itemTypeColor: Color {
        switch result {
        case .artist: return .neonCyan
        case .album: return .neonPink
        case .track: return .neonPurple
        }
    }

    private var itemTypeIcon: String {
        switch result {
        case .artist: return "person.circle.fill"
        case .album: return "square.stack.fill"
        case .track: return "music.note"
        }
    }

    private var name: String {
        switch result {
        case .artist(let artist): return artist.name
        case .album(let album): return album.name
        case .track(let track): return track.name
        }
    }

    private var subtitle: String? {
        switch result {
        case .artist: return nil
        case .album(let album): return album.artistName
        case .track(let track): return track.artistName
        }
    }

    private var artworkURL: String? {
        switch result {
        case .artist(let artist): return artist.artworkURL
        case .album(let album): return album.artworkURL
        case .track(let track): return track.artworkURL
        }
    }
}

// MARK: - Preview
#Preview {
    SearchView()
}
