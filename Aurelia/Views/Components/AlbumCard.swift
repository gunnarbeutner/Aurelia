import SwiftUI

struct AlbumCard: View {
    let album: Album
    /// Passed to the context menu: an artist's own page has no use for a link
    /// back to that artist.
    var offersGoToArtist = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Album Artwork
            ZStack {
                if let artworkURL = album.artworkURL, let url = URL(string: artworkURL) {
                    CachedAsyncImage(url: url) { phase in
                        switch phase {
                        case .empty:
                            placeholderArtwork
                        case .success(let image):
                            image
                                .artworkRendering()
                                .aspectRatio(1, contentMode: .fill)
                                .frame(maxWidth: .infinity)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        case .failure:
                            placeholderArtwork
                        @unknown default:
                            placeholderArtwork
                        }
                    }
                    .transaction { $0.animation = nil }
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.appBorder, lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                } else {
                    placeholderArtwork
                }
            }

            // Album Info
            VStack(alignment: .leading, spacing: 4) {
                Text(album.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color.appText)
                    .lineLimit(1)
                    .tracking(-0.15)

                HStack(spacing: 6) {
                    Text(album.artistName)
                        .font(.system(size: 13))
                        .foregroundColor(.appTextSecondary)
                        .lineLimit(1)

                    if let showDate = ShowDateParser.parse(album.name) {
                        Text(ShowDateParser.format(showDate))
                            .font(.appMono)
                            .foregroundColor(.appTextMuted)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.appElevated)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Color.appBorder, lineWidth: 1))
                            .fixedSize()
                    } else if let year = album.year {
                        Text(String(year))
                            .font(.appMono)
                            .foregroundColor(.appTextMuted)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.appElevated)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Color.appBorder, lineWidth: 1))
                            .fixedSize()
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            AlbumContextMenu(album: album, offersGoToArtist: offersGoToArtist)
        }
        .offlineAvailability(.album(album.id))
    }

    private var placeholderArtwork: some View {
        let hue = AlbumPlaceholderHelper.hue(for: album.name)
        let hue2 = (hue + 40.0).truncatingRemainder(dividingBy: 360.0)

        return RoundedRectangle(cornerRadius: 12)
            .fill(
                LinearGradient(
                    colors: [
                        Color(hue: hue / 360.0, saturation: 0.45, brightness: 0.25),
                        Color(hue: hue2 / 360.0, saturation: 0.55, brightness: 0.18)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .aspectRatio(1, contentMode: .fit)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.appBorder, lineWidth: 1)
            )
            .overlay(
                VStack(spacing: 4) {
                    Text(album.name)
                        .font(.system(.caption, weight: .bold))
                        .foregroundColor(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    Text(album.artistName)
                        .font(.system(.caption2))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)
                }
                .padding(8)
            )
    }
}
