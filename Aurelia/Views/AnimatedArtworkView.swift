//
//  AnimatedArtworkView.swift
//  Aurelia
//
//  Draws album artwork, animating it when it has more than one frame.
//
//  `UIImage` keeps only the first frame of an animated image, so artwork that
//  moves arrives looking still. A moving sleeve is handed to SDWebImage, which
//  decodes it with libwebp off the main thread and buffers frames ahead.
//
//  ImageIO can read these too, and doing so is a trap: its animated-WebP
//  decoder costs a full decode per frame — 211ms against libwebp's 14ms on the
//  same sleeve — and it calls back on the main run loop, so one moving cover
//  spends the app's entire frame budget on decoration.
//

import SDWebImageSwiftUI
import SwiftUI
import UIKit

struct AnimatedArtworkView<Placeholder: View>: View {
    let url: URL?
    let placeholder: () -> Placeholder

    @State private var artwork: Artwork = .none
    /// The URL the current artwork belongs to.
    @State private var loadedURL: URL?

    private enum Artwork {
        case none
        case still(UIImage)
        case moving(Data)
    }

    init(url: URL?, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.placeholder = placeholder

        // A cover already decoded and known not to move is drawn immediately. A
        // shelf scrolling back over its own cards must not pay a disk read and a
        // decode, queued behind one actor, to show what is already in memory.
        if let url, let image = ImageCache.shared.stillImageIfKnown(for: url) {
            _artwork = State(initialValue: .still(image))
            _loadedURL = State(initialValue: url)
        }
    }

    var body: some View {
        Group {
            switch artwork {
            case .none:
                placeholder()
            case .still(let image):
                Image(uiImage: image).artworkRendering().scaledToFill()
            case .moving(let data):
                AnimatedImage(data: data)
                    .resizable()
                    .scaledToFill()
            }
        }
        .task(id: url) {
            await load()
        }
    }

    private func load() async {
        guard let url else {
            artwork = .none
            loadedURL = nil
            return
        }

        // This runs again whenever the view is rebuilt, not only when the URL
        // changes. Starting over would clear the image and fetch it back, which
        // reads as a flicker every time the hierarchy is rebuilt around it.
        if loadedURL == url {
            return
        }

        if let image = ImageCache.shared.stillImageIfKnown(for: url) {
            artwork = .still(image)
            loadedURL = url
            return
        }

        artwork = .none
        loadedURL = nil

        // Reading and the still-image decode happen on the cache's actor, so a
        // shelf of these scrolling into view does none of that on the main thread.
        guard let loaded = try? await ImageCache.shared.artwork(from: url) else { return }
        guard !Task.isCancelled else { return }

        loadedURL = url
        switch loaded {
        case .still(let image):
            artwork = .still(image)
        case .animated(let data):
            artwork = .moving(data)
        }
    }
}
