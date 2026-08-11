//
//  LibraryView.swift
//  Aurelia
//
//  Music library with grid/list views and sorting - iOS 26 Liquid Glass + Cypherpunk
//

import SwiftUI

enum ViewMode: String, CaseIterable {
    case grid = "Grid"
    case list = "List"

    var icon: String {
        switch self {
        case .grid: return "square.grid.2x2"
        case .list: return "list.bullet"
        }
    }
}

enum SortOption: String, CaseIterable {
    case nameAsc = "Name (A-Z)"
    case nameDesc = "Name (Z-A)"
    case artistAsc = "Artist (A-Z)"
    case artistDesc = "Artist (Z-A)"
    case yearNewest = "Year (Newest)"
    case yearOldest = "Year (Oldest)"

    func sort(_ albums: [Album]) -> [Album] {
        switch self {
        case .nameAsc:
            return albums.sorted { $0.name < $1.name }
        case .nameDesc:
            return albums.sorted { $0.name > $1.name }
        case .artistAsc:
            return albums.sorted { $0.artistName < $1.artistName }
        case .artistDesc:
            return albums.sorted { $0.artistName > $1.artistName }
        case .yearNewest:
            return albums.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        case .yearOldest:
            return albums.sorted { ($0.year ?? 0) < ($1.year ?? 0) }
        }
    }
}

struct LibraryScrollIndexEntry: Identifiable, Equatable {
    let label: String
    let targetID: String?

    var id: String { label }
}

enum LibraryScrollIndexBuilder {
    static func alphabetical(
        _ items: [(id: String, title: String)]
    ) -> [LibraryScrollIndexEntry] {
        var targets: [String: String] = [:]
        for item in items {
            let label = alphabeticalLabel(for: item.title)
            if targets[label] == nil {
                targets[label] = item.id
            }
        }
        let labels = ["#"]
            + (0...9).map(String.init)
            + "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map(String.init)
        return labels.map { LibraryScrollIndexEntry(label: $0, targetID: targets[$0]) }
    }

    static func decades(
        _ items: [(id: String, year: Int?)]
    ) -> [LibraryScrollIndexEntry] {
        uniqueEntries(items.map { item in
            let label = item.year.map { "\(($0 / 10) * 10)s" } ?? "#"
            return (label: label, targetID: item.id)
        })
    }

    private static func alphabeticalLabel(for title: String) -> String {
        let folded = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        guard let scalar = folded.unicodeScalars.first else { return "#" }
        let label = String(scalar).uppercased()
        if label.range(of: "^[A-Z0-9]$", options: .regularExpression) != nil {
            return label
        }
        return "#"
    }

    private static func uniqueEntries(
        _ items: [(label: String, targetID: String)]
    ) -> [LibraryScrollIndexEntry] {
        var seen = Set<String>()
        return items.compactMap { item in
            guard seen.insert(item.label).inserted else { return nil }
            return LibraryScrollIndexEntry(label: item.label, targetID: item.targetID)
        }
    }
}

func isLibraryLoadCancellation(_ error: Error) -> Bool {
    if error is CancellationError {
        return true
    }

    let nsError = error as NSError
    return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
}

func recentlyPlayedAlbums(from items: [BaseItemDto], baseURL: String) -> [Album] {
    var albumIds = Set<String>()

    return items.compactMap { item in
        guard item.Type == .Audio,
              let albumId = item.AlbumId,
              !albumId.isEmpty,
              albumIds.insert(albumId).inserted else {
            return nil
        }

        return Album(
            id: albumId,
            name: item.Album ?? "Unknown Album",
            artistName: item.AlbumArtist ?? item.artistName,
            artistId: item.ArtistItems?.first?.Id,
            year: item.ProductionYear,
            artworkURL: item.albumArtworkURL(baseURL: baseURL)?.absoluteString
        )
    }
}

struct LibraryView: View {
    @ObservedObject private var libraryStore = LibraryStore.shared
    @ObservedObject var playerManager = PlayerManager.shared
    @ObservedObject var themeManager = ThemeManager.shared
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var albums: [Album] = []
    @State private var serverRecentAlbums: [Album]?
    @State private var artists: [Artist] = []
    @State private var playlists: [Playlist] = []
    @State private var searchText = ""
    @AppStorage("librarySelectedFilter") private var selectedFilter: String = "Artists"
    @AppStorage("librarySortOption") private var sortOption: SortOption = .nameAsc
    @AppStorage("libraryViewModeArtists") private var viewModeArtists: String = ViewMode.list.rawValue
    @AppStorage("libraryViewModeAlbums") private var viewModeAlbums: String = ViewMode.grid.rawValue

    private var viewMode: ViewMode {
        switch selectedFilter {
        case "Albums", "Recent", "Genres": return ViewMode(rawValue: viewModeAlbums) ?? .grid
        default: return ViewMode(rawValue: viewModeArtists) ?? .list
        }
    }
    private func setViewMode(_ mode: ViewMode) {
        switch selectedFilter {
        case "Albums", "Recent", "Genres": viewModeAlbums = mode.rawValue
        default: viewModeArtists = mode.rawValue
        }
    }
    @State private var showSortMenu = false
    // Navigation handled by NavigationStack and NavigationLink
    @State private var isLoading = true
    @State private var isSyncing = false
    @State private var errorMessage: String?
    @State private var showNewPlaylistSheet = false
    
    // Pagination state
    @State private var albumsHasMore = true
    @State private var artistsHasMore = true
    @State private var isLoadingMore = false
    
    // Genres state
    @State private var genres: [Genre] = []
    @State private var selectedGenre: Genre? = nil
    @State private var genreAlbums: [Album] = []
    @State private var isLoadingGenreAlbums = false
    
    // Search debouncing
    @State private var searchDebounceTask: Task<Void, Never>?

    // Scroll position restoration — persisted so it survives navigation pops
    // Scroll restoration handled by LibraryState.shared + ScrollViewReader

    private var columns: [GridItem] {
        sizeClass == .regular 
            ? [GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 16)]
            : [GridItem(.adaptive(minimum: 130), spacing: 16)]
    }

    var filteredAndSortedAlbums: [Album] {
        let sourceAlbums: [Album]
        if selectedFilter == "Recent" {
            if let serverRecentAlbums {
                sourceAlbums = serverRecentAlbums
            } else {
                var seen = Set<String>()
                sourceAlbums = playerManager.recentlyPlayedTracks.compactMap { track in
                    guard let albumID = track.albumId,
                          seen.insert(albumID).inserted else { return nil }
                    return albums.first { $0.id == albumID }
                }
            }
        } else {
            sourceAlbums = albums
        }

        let filtered: [Album]
        if searchText.isEmpty {
            filtered = sourceAlbums
        } else {
            filtered = sourceAlbums.filter { album in
                album.name.localizedCaseInsensitiveContains(searchText) ||
                album.artistName.localizedCaseInsensitiveContains(searchText)
            }
        }

        if selectedFilter == "Recent" {
            return filtered
        }

        return sortOption.sort(filtered)
    }

    var filteredArtists: [Artist] {
        var filtered = artists

        // Apply favorites filter if needed
        if selectedFilter == "Favorites" {
            filtered = filtered.filter { $0.isFavorite }
        }

        // Apply search filter
        if !searchText.isEmpty {
            filtered = filtered.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }

        return filtered.sorted { $0.name < $1.name }
    }

    var favoriteAlbums: [Album] {
        albums.filter { $0.isFavorite }
    }

    private var scrollIndexEntries: [LibraryScrollIndexEntry] {
        guard searchText.isEmpty else { return [] }

        switch selectedFilter {
        case "Artists":
            return LibraryScrollIndexBuilder.alphabetical(
                filteredArtists.map { (id: $0.id, title: $0.name) }
            )
        case "Albums":
            let sortedAlbums = filteredAndSortedAlbums
            switch sortOption {
            case .nameAsc, .nameDesc:
                return LibraryScrollIndexBuilder.alphabetical(
                    sortedAlbums.map { (id: $0.id, title: $0.name) }
                )
            case .artistAsc, .artistDesc:
                return LibraryScrollIndexBuilder.alphabetical(
                    sortedAlbums.map { (id: $0.id, title: $0.artistName) }
                )
            case .yearNewest, .yearOldest:
                return LibraryScrollIndexBuilder.decades(
                    sortedAlbums.map { (id: $0.id, year: $0.year) }
                )
            }
        default:
            return []
        }
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
                // Filter Pills
                filterSection

                // View Mode & Sort Controls
                viewControlsSection

                if isSyncing && !isLoading {
                    librarySyncProgressView(compact: true)
                }

                // Content based on filter
                if isLoading {
                    // Loading state
                    Spacer()
                    librarySyncProgressView(compact: false)
                    Spacer()
                } else if let error = errorMessage {
                    // Error state
                    ContentUnavailableView {
                        Label("Error Loading Library", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again") {
                            Task { await syncLibrary() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: scrollIndexEntries.count <= 1) {
                        if selectedFilter == "Favorites" {
                            // Favorites View - Show both artists and albums
                            VStack(alignment: .leading, spacing: 20) {
                                if !filteredArtists.isEmpty {
                                    Text("Favorite Artists")
                                        .font(.appHeadline)
                                        .foregroundColor(Color.appText)
                                        .padding(.horizontal, 20)
                                        .padding(.top, 16)

                                    if viewMode == .grid {
                                        LazyVGrid(columns: columns, spacing: 16) {
                                            ForEach(filteredArtists) { artist in
                                                NavigationLink(value: artist) {
                                                    ArtistCard(artist: artist)
                                                }
                                            }
                                        }
                                        .padding(.horizontal, 20)
                                    } else {
                                        LazyVStack(spacing: 0) {
                                            ForEach(filteredArtists) { artist in
                                                NavigationLink(value: artist) {
                                                    ArtistListRow(artist: artist)
                                                }
                                                .padding(.horizontal, 20)

                                                if artist.id != filteredArtists.last?.id {
                                                    Divider()
                                                        .background(Color.appAccent.opacity(0.2))
                                                        .padding(.horizontal, 20)
                                                }
                                            }
                                        }
                                    }
                                }

                                if !favoriteAlbums.isEmpty {
                                    Text("Favorite Albums")
                                        .font(.appHeadline)
                                        .foregroundColor(Color.appText)
                                        .padding(.horizontal, 20)
                                        .padding(.top, filteredArtists.isEmpty ? 16 : 24)

                                    if viewMode == .grid {
                                        LazyVGrid(columns: columns, spacing: 16) {
                                            ForEach(favoriteAlbums) { album in
                                                NavigationLink(value: album) {
                                                    AlbumCard(album: album)
                                                }
                                                .accessibilityElement(children: .combine)
                                                .accessibilityLabel("Album: \(album.name) by \(album.artistName)")
                                                .accessibilityHint("Double tap to view album")
                                            }
                                        }
                                        .padding(.horizontal, 20)
                                    } else {
                                        LazyVStack(spacing: 0) {
                                            ForEach(favoriteAlbums) { album in
                                                NavigationLink(value: album) {
                                                    AlbumListRow(album: album)
                                                }
                                                .accessibilityElement(children: .combine)
                                                .accessibilityLabel("Album: \(album.name) by \(album.artistName)")
                                                .accessibilityHint("Double tap to view album")
                                                .padding(.horizontal, 20)

                                                if album.id != favoriteAlbums.last?.id {
                                                    Divider()
                                                        .background(Color.appAccent.opacity(0.2))
                                                        .padding(.horizontal, 20)
                                                }
                                            }
                                        }
                                    }
                                }

                                if filteredArtists.isEmpty && favoriteAlbums.isEmpty {
                                    ContentUnavailableView {
                                        Label("No Favorites Yet", systemImage: "heart.slash")
                                    } description: {
                                        Text("Tap the heart icon on albums and artists to add them here")
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 100)
                                }
                            }
                        } else if selectedFilter == "Artists" {
                            // Artists View
                            if viewMode == .grid {
                                LazyVGrid(columns: columns, spacing: 16) {
                                    ForEach(filteredArtists) { artist in
                                        NavigationLink(value: artist) {
                                            ArtistCard(artist: artist)
                                        }
                                        .id(artist.id)
                                        .accessibilityElement(children: .combine)
                                        .accessibilityLabel("Artist: \(artist.name)")
                                        .accessibilityHint("Double tap to view artist albums")
                                        .simultaneousGesture(TapGesture().onEnded {
                                            LibraryState.shared.lastTappedArtistId = artist.id
                                        })
                                    }
                                    
                                    // Load more indicator for artists
                                    if isLoadingMore && selectedFilter == "Artists" && artistsHasMore {
                                        VStack {
                                            ProgressView()
                                                .tint(.appAccent)
                                                .scaleEffect(0.8)
                                            Text("Loading more artists...")
                                                .font(.appCaption)
                                                .foregroundColor(.appTextSecondary)
                                        }
                                        .padding()
                                        .gridCellColumns(2)
                                    }
                                }
                                .padding(.horizontal, 20)
                                .padding(.top, 16)
                            } else {
                                LazyVStack(spacing: 0) {
                                    ForEach(filteredArtists) { artist in
                                        NavigationLink(value: artist) {
                                            ArtistListRow(artist: artist)
                                        }
                                        .id(artist.id)
                                        .accessibilityElement(children: .combine)
                                        .accessibilityLabel("Artist: \(artist.name)")
                                        .accessibilityHint("Double tap to view artist albums")
                                        .simultaneousGesture(TapGesture().onEnded {
                                            LibraryState.shared.lastTappedArtistId = artist.id
                                        })
                                        .padding(.horizontal, 20)

                                        if artist.id != filteredArtists.last?.id {
                                            Divider()
                                                .background(Color.appAccent.opacity(0.2))
                                                .padding(.horizontal, 20)
                                        }
                                    }
                                    
                                    // Load more indicator for artists
                                    if isLoadingMore && selectedFilter == "Artists" && artistsHasMore {
                                        HStack {
                                            ProgressView()
                                                .tint(.appAccent)
                                                .scaleEffect(0.8)
                                            Text("Loading more artists...")
                                                .font(.appCaption)
                                                .foregroundColor(.appTextSecondary)
                                        }
                                        .padding()
                                    }
                                }
                                .padding(.top, 16)
                            }
                        } else if selectedFilter == "Playlists" {
                            // Playlists View
                            if playlists.isEmpty {
                                ContentUnavailableView {
                                    Label("No Playlists Yet", systemImage: "music.note.list")
                                } description: {
                                    Text("Create your first playlist to organize your favorite tracks")
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.top, 100)
                            } else {
                                if viewMode == .grid {
                                    LazyVGrid(columns: columns, spacing: 16) {
                                        ForEach(playlists) { playlist in
                                            NavigationLink(value: playlist) {
                                                PlaylistCard(playlist: playlist)
                                            }
                                            .accessibilityElement(children: .combine)
                                            .accessibilityLabel("Playlist: \(playlist.name), \(playlist.trackCount) track\(playlist.trackCount == 1 ? "" : "s")")
                                            .accessibilityHint("Double tap to view playlist")
                                        }
                                    }
                                    .padding(.horizontal, 20)
                                    .padding(.top, 16)
                                } else {
                                    LazyVStack(spacing: 0) {
                                        ForEach(playlists) { playlist in
                                            NavigationLink(value: playlist) {
                                                PlaylistListRow(playlist: playlist)
                                            }
                                            .accessibilityElement(children: .combine)
                                            .accessibilityLabel("Playlist: \(playlist.name), \(playlist.trackCount) track\(playlist.trackCount == 1 ? "" : "s")")
                                            .accessibilityHint("Double tap to view playlist")
                                            .padding(.horizontal, 20)

                                            if playlist.id != playlists.last?.id {
                                                Divider()
                                                    .background(Color.appAccent.opacity(0.2))
                                                    .padding(.horizontal, 20)
                                            }
                                        }
                                    }
                                    .padding(.top, 16)
                                }
                            }
                        } else if selectedFilter == "Genres" {
                            // Genres View
                            if genres.isEmpty {
                                ContentUnavailableView {
                                    Label("No Genres", systemImage: "music.quarternote.3")
                                } description: {
                                    Text("No music genres found in your library")
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.top, 100)
                            } else if let genre = selectedGenre {
                                // Genre albums drill-down
                                VStack(alignment: .leading, spacing: 0) {
                                    Button {
                                        withAnimation(.spring(response: 0.3)) {
                                            selectedGenre = nil
                                            genreAlbums = []
                                        }
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "chevron.left")
                                                .font(.caption.weight(.semibold))
                                            Text(genre.name)
                                                .font(.system(size: 14, weight: .semibold))
                                        }
                                        .foregroundColor(.appAccent)
                                    }
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 12)

                                    if isLoadingGenreAlbums {
                                        HStack { Spacer(); ProgressView().tint(.appAccent); Spacer() }
                                            .padding(.top, 40)
                                    } else if viewMode == .grid {
                                        LazyVGrid(columns: columns, spacing: 16) {
                                            ForEach(genreAlbums) { album in
                                                NavigationLink(value: album) {
                                                    AlbumCard(album: album)
                                                }
                                            }
                                        }
                                        .padding(.horizontal, 20)
                                        .padding(.top, 8)
                                    } else {
                                        LazyVStack(spacing: 0) {
                                            ForEach(genreAlbums) { album in
                                                NavigationLink(value: album) {
                                                    AlbumListRow(album: album)
                                                }
                                                .padding(.horizontal, 20)
                                                if album.id != genreAlbums.last?.id {
                                                    Divider().background(Color.appAccent.opacity(0.2)).padding(.horizontal, 20)
                                                }
                                            }
                                        }
                                        .padding(.top, 8)
                                    }
                                }
                            } else {
                                // Genre list
                                LazyVStack(spacing: 0) {
                                    ForEach(genres) { genre in
                                        Button {
                                            withAnimation(.spring(response: 0.3)) {
                                                selectedGenre = genre
                                            }
                                            Task { await loadGenreAlbums(genreId: genre.id) }
                                        } label: {
                                            HStack {
                                                Text(genre.name)
                                                    .font(.system(size: 16, weight: .medium))
                                                    .foregroundColor(.appText)
                                                Spacer()
                                                if let count = genre.albumCount, count > 0 {
                                                    Text("\(count)")
                                                        .font(.appMono)
                                                        .foregroundColor(.appTextMuted)
                                                        .padding(.horizontal, 8)
                                                        .padding(.vertical, 3)
                                                        .background(Color.appElevated)
                                                        .clipShape(Capsule())
                                                }
                                                Image(systemName: "chevron.right")
                                                    .font(.caption.weight(.semibold))
                                                    .foregroundColor(.appTextMuted)
                                            }
                                            .padding(.horizontal, 20)
                                            .padding(.vertical, 14)
                                        }
                                        if genre.id != genres.last?.id {
                                            Divider().background(Color.white.opacity(0.05)).padding(.horizontal, 20)
                                        }
                                    }
                                }
                                .padding(.top, 8)
                            }
                        } else {
                            // Albums View (and Recent for now)
                            if viewMode == .grid {
                                LazyVGrid(columns: columns, spacing: 16) {
                                    ForEach(filteredAndSortedAlbums) { album in
                                        NavigationLink(value: album) {
                                            AlbumCard(album: album)
                                        }
                                        .id(album.id)
                                        .accessibilityElement(children: .combine)
                                        .accessibilityLabel("Album: \(album.name) by \(album.artistName)")
                                        .accessibilityHint("Double tap to view album")
                                        .simultaneousGesture(TapGesture().onEnded {
                                            LibraryState.shared.lastTappedAlbumId = album.id
                                        })
                                    }
                                    
                                    // Load more indicator for albums
                                    if isLoadingMore && (selectedFilter == "Albums" || selectedFilter == "Recent") && albumsHasMore {
                                        VStack {
                                            ProgressView()
                                                .tint(.appAccent)
                                                .scaleEffect(0.8)
                                            Text("Loading more albums...")
                                                .font(.appCaption)
                                                .foregroundColor(.appTextSecondary)
                                        }
                                        .padding()
                                        .gridCellColumns(2)
                                    }
                                }
                                .padding(.horizontal, 20)
                                .padding(.top, 16)
                            } else {
                                LazyVStack(spacing: 0) {
                                    ForEach(filteredAndSortedAlbums) { album in
                                        NavigationLink(value: album) {
                                            AlbumListRow(album: album)
                                        }
                                        .id(album.id)
                                        .accessibilityElement(children: .combine)
                                        .accessibilityLabel("Album: \(album.name) by \(album.artistName)")
                                        .accessibilityHint("Double tap to view album")
                                        .simultaneousGesture(TapGesture().onEnded {
                                            LibraryState.shared.lastTappedAlbumId = album.id
                                        })
                                        .padding(.horizontal, 20)

                                        if album.id != filteredAndSortedAlbums.last?.id {
                                            Divider()
                                                .background(Color.appAccent.opacity(0.2))
                                                .padding(.horizontal, 20)
                                        }
                                    }
                                    
                                    // Load more indicator for albums
                                    if isLoadingMore && (selectedFilter == "Albums" || selectedFilter == "Recent") && albumsHasMore {
                                        HStack {
                                            ProgressView()
                                                .tint(.appAccent)
                                                .scaleEffect(0.8)
                                            Text("Loading more albums...")
                                                .font(.appCaption)
                                                .foregroundColor(.appTextSecondary)
                                        }
                                        .padding()
                                    }
                                }
                                .padding(.top, 16)
                            }
                        }
                    }
                    .onAppear {
                        // Restore scroll position when navigating back from detail view
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            let state = LibraryState.shared
                            let savedId: String
                            switch selectedFilter {
                            case "Artists": savedId = state.lastTappedArtistId
                            case "Albums": savedId = state.lastTappedAlbumId
                            default: return
                            }
                            if !savedId.isEmpty {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo(savedId, anchor: .center)
                                }
                            }
                        }
                    }
                    .contentMargins(
                        .trailing,
                        scrollIndexEntries.count > 1 ? 28 : 0,
                        for: .scrollContent
                    )
                    .overlay(alignment: .trailing) {
                        if scrollIndexEntries.count > 1 {
                            LibraryScrollIndex(entries: scrollIndexEntries) { entry in
                                guard let targetID = entry.targetID else { return }
                                proxy.scrollTo(targetID, anchor: .top)
                            }
                            .padding(.vertical, 8)
                            .padding(.trailing, 3)
                        }
                    }
                } // end ScrollView
                } // end ScrollViewReader
            }
        }
        .safeAreaInset(edge: .bottom) {
            // Reserves space for mini player (64px) when a track is playing so the
            // last list item is never hidden behind the floating player bar.
            if playerManager.currentTrack != nil {
                Color.clear.frame(height: 72)
            }
        }
        .refreshable {
            await syncLibrary()
        }
        .onChange(of: selectedFilter) { _, newFilter in
            if newFilter == "Recent" {
                serverRecentAlbums = libraryStore.recentAlbums
            }
        }
        // Search moved inline to filterSection
        .onChange(of: searchText) { _, newValue in
            // Cancel previous search task
            searchDebounceTask?.cancel()
            
            // Debounce search for large libraries (300ms delay)
            searchDebounceTask = Task {
                do {
                    try await Task.sleep(nanoseconds: 300_000_000) // 300ms
                    // Search logic is handled by computed properties, no additional action needed
                } catch {
                    // Task was cancelled, ignore
                }
            }
        }
        .navigationDestination(for: Artist.self) { artist in
            ArtistDetailView(artist: artist)
        }
        .navigationDestination(for: Album.self) { album in
            AlbumDetailView(album: album)
        }
        .navigationDestination(for: Playlist.self) { playlist in
            PlaylistDetailView(playlist: playlist)
        }
        .navigationBarHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top) {
            // Custom top bar: logo + Library + sync
            HStack(spacing: 10) {
                Image("AureliaLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 30, height: 30)
                
                Text("Library")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(Color.appText)
                
                Spacer()
                
                // New Playlist button
                if selectedFilter == "Playlists" {
                    Button {
                        showNewPlaylistSheet = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundColor(.neonPink)
                    }
                }
                
                // Sync button
                Button {
                    Task { await syncLibrary() }
                } label: {
                    if isSyncing {
                        ProgressView()
                            .tint(.appAccent)
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.title3)
                            .foregroundColor(.appAccent)
                    }
                }
                .disabled(isSyncing)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Color.appBackground.opacity(0.95))
        }
        .toolbar(.visible, for: .tabBar)
        .sheet(isPresented: $showNewPlaylistSheet) {
            NewPlaylistSheet { playlistId in
                // Refresh playlists after creation
                Task {
                    await syncLibrary()
                }
            }
        }
        .onAppear {
            if albums.isEmpty && artists.isEmpty {
                Task {
                    await fetchLibrary()
                }
            }
        }
        .onReceive(libraryStore.$albums) { albums = $0 }
        .onReceive(libraryStore.$artists) { artists = $0 }
        .onReceive(libraryStore.$playlists) { playlists = $0 }
        .onReceive(libraryStore.$genres) { genres = $0 }
        .onReceive(libraryStore.$recentAlbums) { serverRecentAlbums = $0 }
        .onReceive(libraryStore.$isInitialLoading) { isLoading = $0 }
        .onReceive(libraryStore.$isRefreshing) { isSyncing = $0 }
        .onReceive(libraryStore.$errorMessage) { errorMessage = $0 }
    }

    @ViewBuilder
    private func librarySyncProgressView(compact: Bool) -> some View {
        VStack(spacing: compact ? 6 : 14) {
            if let progress = libraryStore.syncProgress {
                ProgressView(value: progress)
                    .tint(.appAccent)
                    .frame(maxWidth: compact ? .infinity : 320)
            } else {
                ProgressView()
                    .tint(.appAccent)
                    .scaleEffect(compact ? 0.85 : 1.25)
            }

            HStack(spacing: 8) {
                Text(libraryStore.syncMessage ?? "Preparing library sync…")
                    .font(compact ? .appCaption : .appBody)
                    .foregroundColor(.appTextSecondary)
                if let progress = libraryStore.syncProgress {
                    Text("\(Int(progress * 100))%")
                        .font(.appMono)
                        .foregroundColor(.appTextMuted)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, compact ? 6 : 12)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Genre Loading

    private func loadGenreAlbums(genreId: String) async {
        await MainActor.run { isLoadingGenreAlbums = true }
        let albums = await libraryStore.albums(inGenre: genreId)
        await MainActor.run {
            self.genreAlbums = albums
            self.isLoadingGenreAlbums = false
        }
    }

    // MARK: - Library Management

    /// Sync library - force refresh from server
    private func syncLibrary() async {
        await libraryStore.refresh(trigger: .pullToRefresh)
    }

    // MARK: - Fetch Library
    private func fetchLibrary() async {
        await libraryStore.activate()
    }

    // MARK: - Header Section
    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Image("AureliaLogo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 28, height: 28)
                    
                    Text("Library")
                        .font(.appTitle)
                        .foregroundColor(Color.appText)
                }

                Text("\(albums.count) Albums · \(artists.count) Artists")
                    .font(.appCaption)
                    .foregroundColor(.appTextSecondary)
            }

            Spacer()

            // New Playlist button (only show when Playlists filter is selected)
            if selectedFilter == "Playlists" {
                Button {
                    showNewPlaylistSheet = true
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.appMidBackground)
                            .frame(width: 44, height: 44)
                            .overlay(
                                Circle()
                                    .stroke(Color.neonPink.opacity(0.5), lineWidth: 1)
                            )

                        Image(systemName: "plus.circle.fill")
                            .font(.title3.weight(.semibold))
                            .foregroundColor(.neonPink)
                    }
                }
            }

            // Sync button
            Button {
                Task {
                    await syncLibrary()
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.appMidBackground)
                        .frame(width: 44, height: 44)
                        .overlay(
                            Circle()
                                .stroke(Color.appAccent.opacity(0.5), lineWidth: 1)
                        )

                    if isSyncing {
                        ProgressView()
                            .tint(.appAccent)
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.headline.weight(.semibold))
                            .foregroundColor(.appAccent)
                    }
                }
            }
            .disabled(isSyncing)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 20)
    }

    // MARK: - Filter Section
    private var filterSection: some View {
        VStack(spacing: 10) {
            // Inline search
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundColor(.appTextSecondary)
                TextField("Search", text: $searchText)
                    .font(.subheadline)
                    .foregroundColor(Color.appText)
                    .autocorrectionDisabled()
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.appTextSecondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 20)

            // Filter pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(["Artists", "Albums", "Playlists", "Genres", "Recent"], id: \.self) { filter in
                        FilterPill(
                            title: filter,
                            isSelected: selectedFilter == filter
                        ) {
                            withAnimation(.spring(response: 0.3)) {
                                selectedFilter = filter
                            }
                        }
                        .accessibilityLabel("Filter: \(filter)")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAddTraits(selectedFilter == filter ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 20)
            }
        }
        .padding(.bottom, 8)
    }

    // MARK: - View Controls Section
    private var viewControlsSection: some View {
        HStack(spacing: 12) {
            // Sort Button
            Button {
                showSortMenu = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.caption)
                    Text(sortOption.rawValue)
                        .font(.appCaption)
                }
                .foregroundColor(Color.appText)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.1))
                )
                .overlay(
                    Capsule()
                        .stroke(Color.appSecondary.opacity(0.4), lineWidth: 1)
                )
            }
            .accessibilityLabel("Sort by \(sortOption.rawValue)")
            .confirmationDialog("Sort By", isPresented: $showSortMenu, titleVisibility: .visible) {
                ForEach(SortOption.allCases, id: \.self) { option in
                    Button(option.rawValue) {
                        withAnimation(.spring(response: 0.3)) {
                            sortOption = option
                        }
                    }
                }
            }

            Spacer()

            // View Mode Toggle
            HStack(spacing: 0) {
                ForEach(ViewMode.allCases, id: \.self) { mode in
                    Button {
                        withAnimation(.spring(response: 0.3)) {
                            setViewMode(mode)
                        }
                    } label: {
                        Image(systemName: mode.icon)
                            .font(.caption)
                            .foregroundColor(viewMode == mode ? .black : .white)
                            .frame(width: 36, height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: viewMode == mode ? 8 : 0)
                                    .fill(viewMode == mode ? Color.appAccent : Color.clear)
                            )
                    }
                    .accessibilityLabel("\(mode.rawValue) view")
                    .accessibilityAddTraits(viewMode == mode ? .isSelected : [])
                }
            }
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.1))
            )
            .overlay(
                Capsule()
                    .stroke(Color.appAccent.opacity(0.4), lineWidth: 1)
            )
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }
}

private struct LibraryScrollIndex: View {
    let entries: [LibraryScrollIndexEntry]
    let onSelect: (LibraryScrollIndexEntry) -> Void

    @State private var activeEntryID: LibraryScrollIndexEntry.ID?

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                ForEach(entries) { entry in
                    Button {
                        onSelect(entry)
                    } label: {
                        Text(entry.label)
                            .font(.system(size: entries.count > 20 ? 9 : 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(
                                entry.targetID == nil
                                    ? Color.appTextMuted.opacity(0.35)
                                    : (activeEntryID == entry.id ? Color.appText : Color.appAccent)
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background {
                                if activeEntryID == entry.id {
                                    Capsule()
                                        .fill(Color.appAccent.opacity(0.28))
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(entry.targetID == nil)
                    .accessibilityLabel("Jump to \(entry.label)")
                }
            }
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(Color.appElevated.opacity(0.92))
            )
            .overlay {
                Capsule()
                    .stroke(Color.appAccent.opacity(0.22), lineWidth: 1)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        selectEntry(at: value.location.y, height: geometry.size.height)
                    }
                    .onEnded { _ in
                        activeEntryID = nil
                    }
            )
        }
        .frame(width: 22)
    }

    private func selectEntry(at yPosition: CGFloat, height: CGFloat) {
        guard !entries.isEmpty, height > 0 else { return }
        let clampedPosition = min(max(yPosition, 0), height.nextDown)
        let index = min(
            Int(clampedPosition / (height / CGFloat(entries.count))),
            entries.count - 1
        )
        let entry = entries[index]
        guard entry.targetID != nil else { return }
        guard activeEntryID != entry.id else { return }
        activeEntryID = entry.id
        onSelect(entry)
    }
}

// MARK: - Preview
#Preview {
    LibraryView()
}
