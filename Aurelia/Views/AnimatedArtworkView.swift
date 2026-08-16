//
//  AnimatedArtworkView.swift
//  Aurelia
//
//  Draws album artwork, animating it when it has more than one frame.
//
//  `UIImage` keeps only the first frame of an animated image, so artwork that
//  moves arrives looking still. ImageIO reads every frame; this drives them.
//
//  A still image costs what it always did. Only artwork that actually moves
//  pays for a decode per frame, and only while it is on screen.
//

import ImageIO
import SwiftUI
import UIKit

struct AnimatedArtworkView<Placeholder: View>: View {
    let url: URL?
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var frame: Image?
    /// Read by the animation block so it can stop when the view goes away.
    @State private var cancelled = Cancellation()

    var body: some View {
        Group {
            if let frame {
                frame.artworkRendering().scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            await load()
        }
        .onDisappear {
            // The block runs until told otherwise, and a player left open
            // behind another screen should not keep decoding.
            cancelled.isCancelled = true
        }
    }

    private func load() async {
        cancelled.isCancelled = true          // stand down any previous loop
        cancelled = Cancellation()
        frame = nil

        guard let url else { return }
        // Reading and decoding happen on the cache's actor, so a shelf of these
        // scrolling into view does none of that work on the main thread.
        guard let artwork = try? await ImageCache.shared.artwork(from: url) else { return }
        guard !Task.isCancelled else { return }

        switch artwork {
        case .still(let image):
            frame = Image(uiImage: image)

        case .animated(let data):
            let token = cancelled
            // ImageIO calls the block on the main run loop and keeps going
            // until it is told to stop, which is what the token is for.
            CGAnimateImageDataWithBlock(data as CFData, nil) { _, cgImage, stop in
                if token.isCancelled {
                    stop.pointee = true
                    return
                }
                frame = Image(decorative: cgImage, scale: 1)
            }
        }
    }
}

/// A reference the animation block can consult after the view is gone.
/// `CGAnimateImageDataWithBlock` keeps running until its block says otherwise,
/// and the block outlives any value type the view owns.
private final class Cancellation {
    var isCancelled = false
}
