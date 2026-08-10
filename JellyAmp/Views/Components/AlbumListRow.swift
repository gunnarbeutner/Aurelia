import SwiftUI

struct AlbumListRow: View {
    let album: Album
    @State private var showAlbumActions = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Artwork
            Group {
                if let artworkURL = album.artworkURL, let url = URL(string: artworkURL) {
                    CachedAsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 52, height: 52)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        default:
                            placeholderArtwork
                        }
                    }
                    .transaction { $0.animation = nil }
                    .frame(width: 52, height: 52)
                } else {
                    placeholderArtwork
                }
            }

            // Text info — left aligned
            VStack(alignment: .leading, spacing: 3) {
                Text(album.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.jellyAmpText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    Text(album.artistName)
                        .font(.system(size: 13))
                        .foregroundColor(.jellyAmpTextSecondary)
                        .lineLimit(1)

                    if let showDate = ShowDateParser.parse(album.name) {
                        Text("·")
                            .font(.system(size: 13))
                            .foregroundColor(.jellyAmpTextMuted)
                        Text(ShowDateParser.format(showDate))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.jellyAmpTextMuted)
                            .lineLimit(1)
                    } else if let year = album.year {
                        Text(String(year))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.jellyAmpTextMuted)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.jellyAmpElevated)
                            .clipShape(Capsule())
                    }
                }

                if let trackCount = album.trackCount, trackCount > 0 {
                    Text("\(trackCount) tracks")
                        .font(.system(size: 11))
                        .foregroundColor(.jellyAmpTextMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Chevron
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.jellyAmpTextMuted)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onLongPressGesture {
            showAlbumActions = true
        }
        .confirmationDialog(
            album.name,
            isPresented: $showAlbumActions,
            titleVisibility: .visible
        ) {
            AlbumContextMenu(album: album)
        }
    }

    private var placeholderArtwork: some View {
        let hue = AlbumPlaceholderHelper.hue(for: album.name)
        let hue2 = (hue + 40.0).truncatingRemainder(dividingBy: 360.0)
        return ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(LinearGradient(
                    colors: [
                        Color(hue: hue / 360.0, saturation: 0.45, brightness: 0.25),
                        Color(hue: hue2 / 360.0, saturation: 0.55, brightness: 0.18)
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .frame(width: 52, height: 52)
            Text(String(album.name.prefix(1)).uppercased())
                .font(.system(.callout, weight: .bold))
                .foregroundColor(.white.opacity(0.6))
        }
    }
}
