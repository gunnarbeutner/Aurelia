//
//  SearchView.swift
//  Aurelia
//
//  Search across artists, albums, and tracks - Cypherpunk theme
//

import SwiftUI
import UIKit

struct SearchView: View {
    let searchFocusRequest: Int
    @ObservedObject var playerManager = PlayerManager.shared
    @ObservedObject private var keyboard = KeyboardObserver.shared
    @ObservedObject private var lidarr = LidarrService.shared
    private let repository = LibraryRepository.shared
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dismissSearch) private var dismissSearch

    @State private var searchText = ""
    @State private var searchResults: [LibrarySearchResult] = []
    @State private var isSearching = false
    @State private var selectedSource: SearchSource = .library
    @State private var selectedFilter: SearchFilter = .all
    @State private var searchTask: Task<Void, Never>?
    @State private var requestError: String?
    @FocusState private var isSearchFieldFocused: Bool
    // Navigation handled by NavigationStack

    init(searchFocusRequest: Int = 0) {
        self.searchFocusRequest = searchFocusRequest
    }

    enum SearchSource: String, CaseIterable {
        case library = "Library"
        case addMusic = "Add Music"

        var icon: String {
            switch self {
            case .library: return "music.note.list"
            case .addMusic: return "plus.circle.fill"
            }
        }
    }

    enum SearchFilter: String, CaseIterable {
        case all = "All"
        case artists = "Artists"
        case albums = "Albums"
        case tracks = "Tracks"
        case playlists = "Playlists"
    }

    var body: some View {
        ZStack {
            // Background
            LinearGradient(
                colors: [
                    Color.appBackground,
                    Color.appMidBackground,
                    Color.appBackground
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
                } else if selectedSource == .addMusic && lidarr.isSearching {
                    loadingView
                } else if selectedSource == .addMusic && lidarr.searchResults.isEmpty {
                    noResultsView
                } else if selectedSource == .addMusic {
                    lidarrSearchResultsList
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
        .searchable(text: $searchText, prompt: searchPrompt)
        .appSearchFocused($isSearchFieldFocused)
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
        .onChange(of: selectedSource) { _, _ in
            performSearch(query: searchText)
        }
        .onChange(of: canAddMusic) { _, allowed in
            if !allowed && selectedSource == .addMusic {
                selectedSource = .library
            }
        }
        .navigationDestination(for: Album.self) { album in
            AlbumDetailView(album: album)
        }
        .navigationDestination(for: Artist.self) { artist in
            ArtistDetailView(artist: artist)
        }
        .navigationDestination(for: Playlist.self) { playlist in
            PlaylistDetailView(playlist: playlist)
        }
        .rootTabNavigationTitle("Search")
        .task {
            await lidarr.refreshStatus()
            if lidarr.status?.configured == true && lidarr.status?.canRequest == true {
                await lidarr.refreshRequests()
            }
        }
        .alert("Request Failed", isPresented: Binding(
            get: { requestError != nil },
            set: { if !$0 { requestError = nil } }
        )) {
            Button("OK", role: .cancel) { requestError = nil }
        } message: {
            Text(requestError ?? "The album could not be requested.")
        }
    }

    #if targetEnvironment(macCatalyst)
    private var catalystSearchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.appTextSecondary)

            TextField(searchPrompt, text: $searchText)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($isSearchFieldFocused)
                .focusEffectDisabled()

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.appTextSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(
            Capsule()
                .fill(Color.appElevated)
                .overlay(
                    Capsule().stroke(
                        isSearchFieldFocused
                            ? Color.appAccent.opacity(0.45)
                            : Color.appBorder,
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

    private var canAddMusic: Bool {
        lidarr.status?.configured == true && lidarr.status?.canRequest == true
    }

    private var searchPrompt: String {
        selectedSource == .addMusic
            ? "Search albums and artists to add…"
            : "Search artists, albums, tracks…"
    }

    // MARK: - Filter Tabs
    private var filterTabs: some View {
        VStack(spacing: 12) {
            if canAddMusic {
                HStack(spacing: 8) {
                    ForEach(SearchSource.allCases, id: \.self) { source in
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                selectedSource = source
                            }
                        } label: {
                            Label(source.rawValue, systemImage: source.icon)
                                .font(.subheadline.weight(.bold))
                                .foregroundColor(selectedSource == source ? .appAccentText : .appText)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background {
                                    Capsule().fill(
                                        selectedSource == source ? Color.appAccent : Color.appElevated
                                    )
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(
                            "search-source-\(source == .library ? "library" : "add-music")"
                        )
                        .accessibilityAddTraits(selectedSource == source ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 16)
            }

            if selectedSource == .library {
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
                                    .foregroundColor(selectedFilter == filter ? .appAccentText : .appAccent)
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 10)
                                    .background {
                                        if selectedFilter == filter {
                                            Capsule().fill(Color.appAccent)
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
            }
        }
        .padding(.vertical, 16)
    }

    // MARK: - Results List
    private var searchResultsList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
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
                        .offlineAvailability(.artist(artist.id))
                    case .album(let album):
                        NavigationLink(value: album) {
                            SearchResultRow(result: result)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("search-result-\(album.id)")
                        .contextMenu {
                            AlbumContextMenu(album: album)
                        }
                        .offlineAvailability(.album(album.id))
                    case .track(let track):
                        Button { handleTrackTap(track) } label: {
                            SearchResultRow(result: result)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("search-result-\(track.id)")
                        .contextMenu {
                            TrackContextMenu(track: track)
                        }
                        .offlineAvailability(.track(track.id))
                    case .playlist(let playlist):
                        NavigationLink(value: playlist) {
                            SearchResultRow(result: result)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("search-result-\(playlist.id)")
                        .contextMenu {
                            PlaylistContextMenu(playlist: playlist)
                        }
                        .offlineAvailability(.playlist(playlist.id))
                    }
                }

                Color.clear.frame(height: 20)
            }
            .padding(.top, 8)
        }
        .accessibilityIdentifier("search-results-list")
        // Immediately rather than interactively: dismissing brings back the
        // mini player and the strip reserved for it, and tying that to the drag
        // would reflow the list under the finger doing the scrolling.
        .scrollDismissesKeyboard(.immediately)
        .onChange(of: keyboard.isVisible) { _, isVisible in
            // Resigning first responder leaves SwiftUI's focus binding set, so
            // the field would still read as focused — and look it — with no
            // keyboard. Follow the keyboard down.
            guard !isVisible else { return }
            isSearchFieldFocused = false
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Nothing sits in this strip while typing: the tab bar is behind
            // the keyboard and the mini player has stood down.
            if playerManager.currentTrack != nil, !keyboard.isVisible {
                // Clear, not filled: this exists to reserve room so the last
                // result can scroll clear of the mini player. Painting it drew
                // a slab across the bottom of the list instead.
                Color.clear
                    .frame(height: MiniPlayerLayout.contentClearance)
                    .accessibilityHidden(true)
            }
        }
    }

    private var lidarrSearchResultsList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(lidarr.searchResults) { album in
                    LidarrAlbumResultRow(
                        album: album,
                        request: lidarr.request(for: album.foreignAlbumId),
                        onRequest: { requestAlbum(album) }
                    )
                }
                Color.clear.frame(height: 20)
            }
            .padding(.top, 8)
        }
        .scrollDismissesKeyboard(.immediately)
        .accessibilityIdentifier("lidarr-search-results-list")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if playerManager.currentTrack != nil, !keyboard.isVisible {
                Color.clear
                    .frame(height: MiniPlayerLayout.contentClearance)
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: - Empty State
    private var emptySearchView: some View {
        ContentUnavailableView {
            Label(selectedSource == .addMusic ? "Find Music to Add" : "Search Your Library", systemImage: "magnifyingglass")
        } description: {
            Text(selectedSource == .addMusic ? "Search Lidarr's metadata sources for an album" : "Find artists, albums, and tracks")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Loading State
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(.appAccent)
                .scaleEffect(1.5)

            Text("Searching...")
                .font(.body)
                .foregroundColor(.appTextSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - No Results State
    private var noResultsView: some View {
        ContentUnavailableView {
            Label("No Results", systemImage: "music.note.list")
        } description: {
            Text(selectedSource == .addMusic
                 ? (lidarr.errorMessage ?? "Try a different album or artist")
                 : "Try a different search term")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions
    private func requestAlbum(_ album: LidarrAlbumResult) {
        Task {
            do {
                try await lidarr.request(album)
            } catch {
                requestError = error.localizedDescription
            }
        }
    }

    private func performSearch(query: String) {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()

        guard !normalizedQuery.isEmpty else {
            searchResults = []
            lidarr.clearSearch()
            isSearching = false
            searchTask = nil
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

        // Enter loading state before the debounce so an old empty result does
        // not flash "No Results" while the user is still typing.
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3 seconds
            guard !Task.isCancelled else { return }

            if selectedSource == .addMusic {
                await lidarr.search(normalizedQuery)
                isSearching = false
                return
            }

            do {
                guard let scope = JellyfinService.shared.libraryScope else {
                    throw JellyfinError.notAuthenticated
                }
                let results = try await repository.search(
                    normalizedQuery,
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
        case .playlists: return .playlists
        }
    }
}

private struct LidarrAlbumResultRow: View {
    let album: LidarrAlbumResult
    let request: LidarrRequest?
    let onRequest: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            CachedAsyncImage(url: album.imageUrl.flatMap(URL.init(string:))) { phase in
                if case .success(let image) = phase {
                    image.artworkRendering().aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Color.appElevated
                        Image(systemName: "square.stack.fill").foregroundColor(.appTextSecondary)
                    }
                }
            }
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 5) {
                Text(album.title).font(.body.weight(.semibold)).foregroundColor(.appText).lineLimit(1)
                HStack(spacing: 6) {
                    Text("ALBUM")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.appAccent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.appAccent.opacity(0.15), in: Capsule())
                    Text([album.artistName, album.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundColor(.appTextSecondary)
                        .lineLimit(1)
                }
                if request?.state == .failed, let error = request?.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            Spacer()

            if let request, request.state == .failed {
                Button(action: onRequest) {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.appAccentText)
                }
                    .buttonStyle(AppProminentButtonStyle())
                    .accessibilityLabel("Retry adding \(album.title) album")
            } else if let request {
                Label(request.state.displayName, systemImage: request.state.icon)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(request.state == .failed ? .red : .appAccent)
            } else {
                Button(action: onRequest) {
                    Text("Add Album")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.appAccentText)
                }
                    .buttonStyle(AppProminentButtonStyle())
                    .accessibilityLabel("Add \(album.title) album")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.appMidBackground.opacity(0.3)))
        .padding(.horizontal, 16)
    }
}

extension LidarrRequestState {
    var displayName: String {
        switch self {
        case .requested: "Requested"
        case .searching: "Searching"
        case .queued: "Queued"
        case .downloading: "Downloading"
        case .waitingForJellyfin: "Importing"
        case .available: "Available"
        case .failed: "Failed"
        }
    }

    var icon: String {
        switch self {
        case .requested, .queued: "clock"
        case .searching: "magnifyingglass"
        case .downloading: "arrow.down.circle"
        case .waitingForJellyfin: "arrow.triangle.2.circlepath"
        case .available: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}

private extension View {
    @ViewBuilder
    func appSearchFocused(_ focus: FocusState<Bool>.Binding) -> some View {
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
                                .artworkRendering()
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
                        .foregroundColor(Color.appText)
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
                                    .foregroundColor(.appTextSecondary)
                                    .lineLimit(1)
                            }
                        } else if let subtitle {
                            // Show artist name for albums/tracks
                            Text(subtitle)
                                .font(.subheadline)
                                .foregroundColor(.appTextSecondary)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer()

                // Chevron
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.appTextSecondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.appMidBackground.opacity(0.3))
            )
            .contentShape(Rectangle())
        .padding(.horizontal, 16)
    }

    private var placeholderImage: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    LinearGradient(
                        colors: [Color.appAccent.opacity(0.3), Color.appTertiary.opacity(0.3)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 60, height: 60)

            Image(systemName: itemTypeIcon)
                .font(.title2)
                .foregroundColor(.appTextSecondary)
        }
    }

    private var itemTypeLabel: String {
        switch result {
        case .artist: return "ARTIST"
        case .album: return "ALBUM"
        case .track: return "TRACK"
        case .playlist: return "PLAYLIST"
        }
    }

    private var itemTypeColor: Color {
        switch result {
        case .artist: return .appAccent
        case .album: return .appSecondary
        case .track: return .appTertiary
        case .playlist: return .appAccent
        }
    }

    private var itemTypeIcon: String {
        switch result {
        case .artist: return "person.circle.fill"
        case .album: return "square.stack.fill"
        case .track: return "music.note"
        case .playlist: return "music.note.list"
        }
    }

    private var name: String {
        switch result {
        case .artist(let artist): return artist.name
        case .album(let album): return album.name
        case .track(let track): return track.name
        case .playlist(let playlist): return playlist.name
        }
    }

    private var subtitle: String? {
        switch result {
        case .artist: return nil
        case .album(let album): return album.artistName
        case .track(let track): return track.artistName
        case .playlist(let playlist):
            return "\(playlist.trackCount) track\(playlist.trackCount == 1 ? "" : "s")"
        }
    }

    private var artworkURL: String? {
        switch result {
        case .artist(let artist): return artist.artworkURL
        case .album(let album): return album.artworkURL
        case .track(let track): return track.artworkURL
        case .playlist(let playlist): return playlist.artworkURL
        }
    }
}

// MARK: - Preview
#Preview {
    SearchView()
}
