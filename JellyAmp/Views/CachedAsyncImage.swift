//
//  CachedAsyncImage.swift
//  JellyAmp
//
//  Drop-in replacement for AsyncImage with memory + disk caching
//

import SwiftUI

struct CachedAsyncImage<Content: View>: View {
    let url: URL?
    let content: (AsyncImagePhase) -> Content

    @State private var phase: AsyncImagePhase = .empty
    @State private var wasCacheHit = false

    init(url: URL?, @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
        self.url = url
        self.content = content
        if let url, let image = ImageCache.shared.cachedMemoryImage(for: url) {
            _phase = State(initialValue: .success(Image(uiImage: image)))
            _wasCacheHit = State(initialValue: true)
        }
    }

    var body: some View {
        content(phase)
            .opacity(phase.image != nil ? 1 : 1)
            .animation(wasCacheHit ? nil : .easeIn(duration: 0.2), value: phase.image != nil)
            .task(id: url) {
                if phase.image == nil {
                    await loadImage()
                }
            }
    }

    private func loadImage() async {
        guard let url = url else {
            phase = .empty
            return
        }

        // Check cache synchronously first
        if let cached = await ImageCache.shared.cachedImage(for: url) {
            wasCacheHit = true
            phase = .success(Image(uiImage: cached))
            return
        }

        // Network fetch
        wasCacheHit = false
        do {
            let img = try await ImageCache.shared.loadImage(from: url)
            phase = .success(Image(uiImage: img))
        } catch {
            phase = .failure(error)
        }
    }
}

/// A cover-art backdrop that always reports the size proposed by its viewport.
/// A square image scaled to fill a tall phone must not widen its parent layout.
struct ViewportBlurredArtwork: View {
    let url: URL
    var opacity: Double = 0.35

    var body: some View {
        GeometryReader { geometry in
            CachedAsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .scaleEffect(1.3)
                        .blur(radius: 80)
                        .saturation(1.5)
                        .opacity(opacity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
    }
}

// Convenience: match the AsyncImage(url:) { phase in ... } pattern
extension AsyncImagePhase {
    var image: Image? {
        if case .success(let img) = self { return img }
        return nil
    }
}
