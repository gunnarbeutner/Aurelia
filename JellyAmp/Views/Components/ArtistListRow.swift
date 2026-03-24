import SwiftUI

struct ArtistListRow: View {
    let artist: Artist
    @State private var wikiImageURL: String?

    private var effectiveArtworkURL: String? {
        artist.artworkURL ?? wikiImageURL
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Artist artwork
            if let artworkURL = effectiveArtworkURL, let url = URL(string: artworkURL) {
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                    default:
                        placeholderArtistArt
                    }
                }
                .transaction { $0.animation = nil }
                .frame(width: 52, height: 52)
            } else {
                placeholderArtistArt
            }

            // Artist info
            VStack(alignment: .leading, spacing: 3) {
                Text(artist.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.jellyAmpText)
                    .lineLimit(1)

                if artist.albumCount > 0 {
                    Text("\(artist.albumCount) albums")
                        .font(.system(size: 12))
                        .foregroundColor(.jellyAmpTextSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Chevron
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.jellyAmpTextMuted)
        }
        .padding(.vertical, 10)
        .task {
            if artist.artworkURL == nil {
                wikiImageURL = await ArtistImageService.shared.getImageURL(for: artist.name)
            }
        }
    }

    private var placeholderArtistArt: some View {
        let hue = ArtistPlaceholderHelper.hue(for: artist.name)
        let hue2 = (hue + 30.0).truncatingRemainder(dividingBy: 360.0)
        return ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(LinearGradient(
                    colors: [
                        Color(hue: hue / 360.0, saturation: 0.4, brightness: 0.28),
                        Color(hue: hue2 / 360.0, saturation: 0.5, brightness: 0.18)
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .frame(width: 52, height: 52)
            Text(ArtistPlaceholderHelper.initials(for: artist.name))
                .font(.system(.callout, weight: .bold))
                .foregroundColor(.white.opacity(0.6))
        }
    }
}
