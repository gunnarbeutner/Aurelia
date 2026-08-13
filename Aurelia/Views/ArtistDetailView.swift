//
//  ArtistDetailView.swift
//  Aurelia
//
//  Artist detail page with discography - iOS 26 Liquid Glass + Cypherpunk
//

import SwiftUI
import PhotosUI

// MARK: - View Mode Enum
enum ArtistViewMode {
    case allAlbums   // list
    case grid        // square grid
    case byYear      // grouped by year
}

struct ArtistDetailView: View {
    let artist: Artist
    @ObservedObject var jellyfinService = JellyfinService.shared
    @ObservedObject var playerManager = PlayerManager.shared
    private let repository = LibraryRepository.shared
    @Environment(\.dismiss) var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var albums: [Album] = []
    @State private var isLoadingAlbums = false
    @State private var hasLoadedAlbums = false
    // Navigation handled by NavigationStack
    @State private var viewMode: ArtistViewMode = .allAlbums
    @State private var selectedYear: Int?
    @State private var isShuffling = false
    @State private var wikiImageURL: String?
    @State private var showPhotoPicker = false
    @State private var isUploadingImage = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var uploadError: String?

    private var effectiveArtworkURL: String? {
        artist.artworkURL ?? wikiImageURL
    }

    /// Index into ``headerImageCandidates``. Advanced when a candidate fails to
    /// load, which is how a missing backdrop falls through to the next choice.
    @State private var headerCandidateIndex = 0

    /// Header art in descending order of suitability. Backdrop and Thumb are
    /// wide images meant for exactly this; the square Primary is the fallback,
    /// and the Wikipedia lookup backs that up when the server has nothing.
    private var headerImageCandidates: [URL] {
        var candidates: [URL] = []
        for kind in [JellyfinService.ArtistImageKind.backdrop, .primary] {
            if let url = jellyfinService.artistImageURL(
                artistID: artist.id,
                kind: kind,
                maxWidth: 1280
            ) {
                candidates.append(url)
            }
        }
        if let wiki = wikiImageURL, let url = URL(string: wiki) {
            candidates.append(url)
        }
        return candidates
    }

    private var headerImageURL: URL? {
        let candidates = headerImageCandidates
        guard candidates.indices.contains(headerCandidateIndex) else { return nil }
        return candidates[headerCandidateIndex]
    }
    @State private var isFavorite: Bool

    init(artist: Artist) {
        self.artist = artist
        _isFavorite = State(initialValue: artist.isFavorite)
    }

    private func loadHeaderImage() async {
        guard let url = headerImageURL else {
            headerImage = nil
            headerTopColor = nil
            return
        }
        // Cached hit or network fetch, whichever applies — the point is that
        // the strip does not have to wait for somebody else to warm the cache.
        guard let image = try? await ImageCache.shared.loadImage(from: url) else {
            headerImage = nil
            headerTopColor = nil
            return
        }
        let color = DominantColorExtractor.shared.dominantColor(
            from: image,
            trackId: artist.id
        )
        withAnimation(.easeInOut(duration: 0.4)) {
            headerImage = image
            headerTopColor = color
        }
    }

    /// The resolved header image. Held here so the strip above the photo and
    /// the colour behind it come from one load: reading the cache alone meant
    /// the strip only appeared on a second visit, once something else had put
    /// the image there.
    @State private var headerImage: UIImage?

    /// Sampled from the header image so the strip behind the status bar and the
    /// Dynamic Island belongs to the picture rather than cutting into it.
    @State private var headerTopColor: Color?

    /// The screen's top inset. Read from the window rather than the layout,
    /// because the scroll view here deliberately ignores the top safe area and
    /// the value would already be consumed by the time the header asks for it.
    private var topInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .map(\.safeAreaInsets.top)
            .max() ?? 0
    }

    var body: some View {
        VStack(spacing: 0) {
            // Main Content
            ZStack {
                // Background: blurred artist art
                ZStack {
                    Color.appBackground.ignoresSafeArea()

                    if let artworkURL = effectiveArtworkURL, let url = URL(string: artworkURL) {
                        ViewportBlurredArtwork(url: url, opacity: 0.3)
                        .ignoresSafeArea()
                    }

                    LinearGradient(
                        colors: [
                            Color.appBackground.opacity(0.4),
                            Color.appBackground.opacity(0.7),
                            Color.appBackground.opacity(0.95)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea()
                }

                ScrollView {
                    VStack(spacing: 0) {
                        // Hero Header with Artist Image, drawn to the top edge.
                        // The negative padding this replaces could not work: a
                        // scroll view clips its content, so pulling the header
                        // up only cut 60pt off the image and left the status
                        // bar showing the page background.
                        artistHeaderSection(topInset: topInset)

                        // Bio Section
                        if let bio = artist.bio {
                            bioSection(bio: bio)
                        }

                        // Albums Section
                        albumsSection

                        // Bottom padding for mini player
                        Color.clear.frame(height: 100)
                    }
                }
                // Top only: the header reaches the screen edge while the
                // bottom keeps its inset for the tab bar and mini player.
                .ignoresSafeArea(edges: .top)

                // Navigation handled by NavigationStack
            }

        }
        .ignoresSafeArea(.keyboard)
        .task(id: headerImageURL) {
            await loadHeaderImage()
        }
        .onAppear {
            guard !hasLoadedAlbums else { return }
            hasLoadedAlbums = true
            Task {
                await fetchArtistAlbums()
            }
        }
        .task {
            if artist.artworkURL == nil {
                wikiImageURL = await ArtistImageService.shared.getImageURL(for: artist.name)
            }
        }
        .navigationDestination(for: Album.self) { album in
            AlbumDetailView(album: album)
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotoItem, matching: .images)
        .onChange(of: selectedPhotoItem) { _, newItem in
            guard let newItem else { return }
            Task {
                isUploadingImage = true
                defer { isUploadingImage = false }
                do {
                    guard let data = try await newItem.loadTransferable(type: Data.self) else {
                        print("❌ Failed to load photo data from picker")
                        uploadError = "Could not load the selected photo"
                        selectedPhotoItem = nil
                        return
                    }
                    guard let uiImage = UIImage(data: data),
                          let jpegData = uiImage.jpegData(compressionQuality: 0.85) else {
                        print("❌ Failed to convert photo to JPEG")
                        uploadError = "Could not process the photo"
                        selectedPhotoItem = nil
                        return
                    }
                    print("📸 Uploading artist image (\(jpegData.count / 1024)KB) for \(artist.name)")
                    try await jellyfinService.uploadImage(itemId: artist.id, imageData: jpegData)
                    print("✅ Artist image uploaded successfully")
                    // Cache-bust: append timestamp so the image reloads
                    let ts = Int(Date().timeIntervalSince1970)
                    let serverImageURL = "\(jellyfinService.baseURL)/Items/\(artist.id)/Images/Primary?t=\(ts)"
                    wikiImageURL = serverImageURL
                } catch {
                    print("❌ Artist image upload failed: \(error)")
                    uploadError = "Upload failed: \(error.localizedDescription)"
                }
                selectedPhotoItem = nil
            }
        }
        .alert("Photo Upload", isPresented: Binding(get: { uploadError != nil }, set: { if !$0 { uploadError = nil } })) {
            Button("OK") { uploadError = nil }
        } message: {
            Text(uploadError ?? "")
        }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(8)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    /// Steps to the next header candidate when one fails to load — typically a
    /// backdrop the server does not have for this artist.
    private func advanceHeaderCandidate() {
        guard headerCandidateIndex < headerImageCandidates.count - 1 else { return }
        headerCandidateIndex += 1
    }

    // MARK: - Fetch Artist Data
    private func fetchArtistAlbums() async {
        await DelayedLoading.run { isLoadingAlbums = $0 } work: {
            guard let scope = jellyfinService.libraryScope else { return }
            albums = (try? await repository.albums(forArtist: artist.id, in: scope)) ?? []
        }
    }

    // MARK: - Toggle Favorite
    private func toggleFavorite() {
        // Optimistic UI update
        withAnimation(.spring(response: 0.3)) {
            isFavorite.toggle()
        }
        let updatedFavoriteValue = isFavorite

        // Call API in background
        Task {
            do {
                if updatedFavoriteValue {
                    try await jellyfinService.markFavorite(itemId: artist.id)
                } else {
                    try await jellyfinService.unmarkFavorite(itemId: artist.id)
                }
                FavoriteMutationCenter.shared.publish(
                    .artist(artist, isFavorite: updatedFavoriteValue)
                )
            } catch {
                // Revert on failure
                await MainActor.run {
                    withAnimation(.spring(response: 0.3)) {
                        isFavorite.toggle()
                    }
                }
                print("Error toggling favorite: \(error)")
            }
        }
    }

    // MARK: - Artist Header Section
    /// Grown by the safe-area inset rather than shifted into it. Bleeding a
    /// fixed-height header to the screen edge moves the whole image up, which
    /// puts the subject's face under the Dynamic Island and clips their head
    /// again; adding the inset to the height instead leaves everything where it
    /// was and fills the strip above with picture instead of page background.
    @ViewBuilder
    private func headerBleed(topInset: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            (headerTopColor ?? Color.appBackground)

            if let headerImage {
                GeometryReader { geo in
                    Image(uiImage: headerImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: 280, alignment: .top)
                        // Flipped, and pinned to the bottom of the strip, so the
                        // row that meets the photo is the photo's own first row.
                        .scaleEffect(y: -1)
                        // Stretched sideways as well as blurred: a mirrored
                        // photograph still reads as a photograph, and detail up
                        // here competes with the status bar. Smeared, it is just
                        // the picture's colour arriving from the right place.
                        .scaleEffect(x: 1.6, y: 1.6)
                        .blur(radius: 28)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
                        .clipped()
                }
            }
        }
        .frame(height: topInset)
        .clipped()
        .allowsHitTesting(false)
    }

    private func artistHeaderSection(topInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            // The strip the status bar and the notch sit in. The picture
            // starts below it, so nothing lands on the subject's face.
            //
            // Filled by mirroring the photo upward from its own top row rather
            // than with a sampled colour: an averaged colour cannot match what
            // it meets — the top edge here is a dark picture frame on one side
            // and a pale wall on the other — so it read as a bar laid over the
            // header. Mirroring matches at the seam by construction, and the
            // blur keeps it from looking like a reflection.
            headerBleed(topInset: topInset)

            // Large artist artwork/gradient
            ZStack {
                if let url = headerImageURL {
                    GeometryReader { geo in
                        CachedAsyncImage(url: url) { phase in
                            switch phase {
                            case .empty:
                                placeholderArtistHeader
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    // Anchored to the top, not centred. Filling
                                    // a short wide header from a portrait
                                    // source spills over both edges, and a
                                    // centred crop takes half of that off the
                                    // top — which is exactly where the face is.
                                    .frame(width: geo.size.width, height: 280, alignment: .top)
                                    .clipped()
                            case .failure:
                                placeholderArtistHeader
                                    .onAppear { advanceHeaderCandidate() }
                            @unknown default:
                                placeholderArtistHeader
                            }
                        }
                        .id(url)
                    }
                    .frame(height: 280)
                    .clipped()
                } else {
                    placeholderArtistHeader
                }
            }
            .frame(height: 280)
            .clipped()
            .overlay(
                LinearGradient(
                    colors: [
                        Color.clear,
                        Color.appBackground.opacity(0.8)
                    ],
                    startPoint: .center,
                    endPoint: .bottom
                )
            )
            .overlay(alignment: .topTrailing) {
                if isUploadingImage {
                    ProgressView()
                        .tint(.white)
                        .padding(12)
                }
            }
            .contextMenu {
                Button {
                    showPhotoPicker = true
                } label: {
                    Label("Set Artist Photo", systemImage: "photo.on.rectangle")
                }
                .tint(nil)
            }

            // Artist Name & Stats
            VStack(spacing: 20) {
                Text(artist.name)
                    .font(.title.weight(.bold))
                    .foregroundColor(Color.appText)
                    .multilineTextAlignment(.center)

                    .padding(.top, -40)
                    .padding(.horizontal, 20)

                // Action Buttons
                HStack(spacing: 12) {
                    // Shuffle Button
                    Button {
                        shuffleArtist()
                    } label: {
                        HStack(spacing: 10) {
                            if isShuffling {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .black))
                                    .scaleEffect(0.9)
                            } else {
                                Image(systemName: "shuffle")
                                    .font(.headline.weight(.semibold))
                            }
                            Text(isShuffling ? "LOADING..." : "SHUFFLE")
                                .font(.body.weight(.bold))
                        }
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            Capsule()
                                .fill(Color.white)
                        )
                    }
                    .disabled(isShuffling)
                    .accessibilityLabel("Shuffle all songs by artist")

                    // Favorite Button
                    Button {
                        toggleFavorite()
                    } label: {
                        Image(systemName: isFavorite ? "heart.fill" : "heart")
                            .font(.title3.weight(.semibold))
                            .foregroundColor(isFavorite ? .appSecondary : .white)
                            .frame(width: 56, height: 56)
                            .background(
                                Circle()
                                    .fill(Color.appControlFill)
                                    .overlay(
                                        Circle()
                                            .stroke(Color.appSecondary.opacity(isFavorite ? 0.8 : 0.5), lineWidth: 1)
                                    )
                            )

                    }
                    .accessibilityLabel(isFavorite ? "Remove artist from favorites" : "Add artist to favorites")
                }

                if artist.albumCount > 0 {
                    HStack(spacing: 8) {
                        Image(systemName: "music.note.list")
                            .font(.caption)
                            .foregroundColor(.appAccent)
                        Text("\(artist.albumCount) album\(artist.albumCount == 1 ? "" : "s")")
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.appTextSecondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(Color.appControlFill)
                    )
                    .overlay(
                        Capsule()
                            .stroke(Color.appAccent.opacity(0.3), lineWidth: 1)
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 30)
        }
    }

    // MARK: - Bio Section
    private func bioSection(bio: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "info.circle.fill")
                    .font(.caption)
                    .foregroundColor(.appAccent)
                Text("About")
                    .font(.headline.weight(.semibold))
                    .foregroundColor(Color.appText)
            }

            Text(bio)
                .font(.subheadline)
                .foregroundColor(.appTextSecondary)
                .lineSpacing(8)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.appSubtleFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.appAccent.opacity(0.2), lineWidth: 1)
                )
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 30)
    }

    private var placeholderArtistHeader: some View {
        ZStack {
            // Gradient background
            LinearGradient(
                colors: [
                    Color.appAccent.opacity(0.6),
                    Color.appSecondary.opacity(0.6),
                    Color.appTertiary.opacity(0.7)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .frame(maxHeight: .infinity)

            // Artist icon overlay
            Image(systemName: "person.circle.fill")
                .font(.largeTitle)
                .foregroundColor(.appTextMuted)
        }
    }

    // MARK: - Albums Section
    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Section Header with View Toggle
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Discography")
                        .font(.title3.weight(.bold))
                        .foregroundColor(Color.appText)

                    if !albums.isEmpty {
                        Text("\(albums.count) album\(albums.count == 1 ? "" : "s")")
                            .font(.appCaption)
                            .foregroundColor(.appTextSecondary)
                    }
                }

                Spacer()

                // View Mode Toggle
                if !albums.isEmpty {
                    HStack(spacing: 0) {
                        ForEach([
                            (ArtistViewMode.allAlbums, "list.bullet", "List"),
                            (ArtistViewMode.grid, "square.grid.2x2", "Grid"),
                            (ArtistViewMode.byYear, "calendar", "By Year")
                        ], id: \.2) { mode, icon, label in
                            Button {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    viewMode = mode
                                }
                            } label: {
                                Image(systemName: icon)
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(viewMode == mode ? .black : .white)
                                    .frame(width: 36, height: 30)
                                    .background(
                                        RoundedRectangle(cornerRadius: viewMode == mode ? 8 : 0)
                                            .fill(viewMode == mode ? Color.appAccent : Color.clear)
                                    )
                            }
                            .accessibilityLabel(label)
                        }
                    }
                    .background(Capsule().fill(Color.appControlFill))
                    .overlay(Capsule().stroke(Color.appAccent.opacity(0.4), lineWidth: 1))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)

            if isLoadingAlbums && albums.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(.appAccent)
                        Text("Loading albums...")
                            .font(.appCaption)
                            .foregroundColor(.appTextSecondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 40)
            } else if albums.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "music.note.list")
                            .font(.title)
                            .foregroundColor(.secondary.opacity(0.5))
                        Text("No albums found")
                            .font(.appBody)
                            .foregroundColor(.appTextSecondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 40)
            } else {
                // Switch between view modes
                switch viewMode {
                case .allAlbums: allAlbumsView
                case .grid: gridAlbumsView
                case .byYear: byYearView
                }
            }
        }
        .padding(.bottom, 30)
    }

    // MARK: - All Albums View
    private var allAlbumsView: some View {
        LazyVStack(spacing: 0) {
            ForEach(albums.sorted(by: { ($0.year ?? 0) > ($1.year ?? 0) })) { album in
                NavigationLink(value: album) {
                    AlbumListRow(album: album, offersGoToArtist: false)
                }
                // AlbumListRow carries no horizontal inset of its own, so the
                // row content aligns with the section header while the tinted
                // background still runs to the edges.
                .padding(.horizontal, 20)
                .background(Color.appMidBackground.opacity(0.3))
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }

    // MARK: - Grid Albums View
    private var gridAlbumsView: some View {
        let columns = [GridItem(.adaptive(minimum: 130), spacing: 12)]
        return LazyVGrid(columns: columns, spacing: 12) {
            ForEach(albums.sorted(by: { ($0.year ?? 0) > ($1.year ?? 0) })) { album in
                NavigationLink(value: album) {
                    AlbumCard(album: album, offersGoToArtist: false)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }

    // MARK: - By Year View
    private var byYearView: some View {
        LazyVStack(spacing: 12) {
            ForEach(albumsByYear.keys.sorted(by: >), id: \.self) { year in
                YearSection(
                    year: year,
                    albums: albumsByYear[year] ?? [],
                    isExpanded: selectedYear == year,
                    onYearTap: {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                            selectedYear = (selectedYear == year) ? nil : year
                        }
                    },
                    onAlbumTap: { _ in
                        // Navigation now handled by NavigationLink
                    }
                )
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }

    // MARK: - Computed Properties
    private var albumsByYear: [Int: [Album]] {
        Dictionary(grouping: albums) { album in
            album.year ?? 0
        }
    }

    // MARK: - Actions
    private func shuffleArtist() {
        guard !isShuffling else { return }

        isShuffling = true

        Task {
            guard let scope = jellyfinService.libraryScope else {
                isShuffling = false
                return
            }
            let allTracks = (try? await repository.tracks(forArtist: artist.id, in: scope)) ?? []

            await MainActor.run {
                isShuffling = false
                if !allTracks.isEmpty {
                    playerManager.play(tracks: Array(allTracks.shuffled().prefix(200)))
                } else {
                    print("No tracks found to shuffle")
                }
            }
        }
    }
}

// MARK: - Stat Badge Component
struct StatBadge: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(.title3, design: .monospaced).weight(.bold))
                .foregroundColor(.appAccent)

            Text(label)
                .font(.appCaption)
                .foregroundColor(.appTextSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(Color.appControlFill)
        )
        .overlay(
            Capsule()
                .stroke(Color.appAccent.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Year Section Component
struct YearSection: View {
    let year: Int
    let albums: [Album]
    let isExpanded: Bool
    let onYearTap: () -> Void
    let onAlbumTap: (Album) -> Void

    private var yearString: String {
        year == 0 ? "Unknown" : String(year)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Year Header Button
            Button {
                onYearTap()
            } label: {
                HStack(alignment: .center) {
                    // Year Text
                    Text(yearString)
                        .font(.title.weight(.bold))
                        .foregroundColor(Color.appText)

                    Spacer()

                    // Album count badge
                    HStack(spacing: 8) {
                        Text("\(albums.count)")
                            .font(.headline.weight(.bold))
                            .foregroundColor(.appAccent)
                        Image(systemName: isExpanded ? "chevron.up.circle.fill" : "chevron.right.circle.fill")
                            .font(.title3.weight(.semibold))
                            .foregroundColor(.appAccent)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        Capsule()
                            .fill(Color.appAccent.opacity(0.15))
                    )
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
                .contentShape(Rectangle())
            }
            .overlay(
                // Bottom border only
                VStack {
                    Spacer()
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.appAccent.opacity(0.3),
                                    Color.appSecondary.opacity(0.2)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(height: 1)
                }
            )

            // Expanded Album List
            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(albums.sorted(by: { ($0.year ?? 0) > ($1.year ?? 0) })) { album in
                        NavigationLink(value: album) {
                            AlbumListRow(album: album, offersGoToArtist: false)
                        }
                        .padding(.horizontal, 20)
                        .background(Color.appMidBackground.opacity(0.2))
                    }
                }
                .padding(.top, 8)
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
    }
}

// MARK: - Preview
#Preview {
    ArtistDetailView(artist: Artist.mockArtists[0])
}
