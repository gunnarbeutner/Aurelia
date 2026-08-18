//
//  NowPlayingEntry.swift
//  AureliaWidgets
//
//  Timeline entry and provider backed by the shared app group
//

import SwiftUI
import WidgetKit

struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let snapshot: NowPlayingSnapshot
    let artwork: Image?
}

struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(date: .now, snapshot: .placeholder, artwork: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        completion(currentEntry())
    }

    // The app reloads this timeline whenever the track or the transport state
    // changes, and a playing entry animates its own clock, so there is nothing
    // for a scheduled refresh to add.
    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        completion(Timeline(entries: [currentEntry()], policy: .never))
    }

    private func currentEntry() -> NowPlayingEntry {
        let snapshot = SharedContainer.loadSnapshot() ?? .placeholder
        return NowPlayingEntry(date: .now, snapshot: snapshot, artwork: loadArtwork(snapshot))
    }

    private func loadArtwork(_ snapshot: NowPlayingSnapshot) -> Image? {
        guard let fileName = snapshot.artworkFileName,
              let url = SharedContainer.artworkURL(named: fileName),
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data)
        else { return nil }
        return Image(uiImage: image)
    }
}
