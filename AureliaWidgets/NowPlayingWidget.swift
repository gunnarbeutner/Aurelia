//
//  NowPlayingWidget.swift
//  AureliaWidgets
//
//  Home and lock screen now-playing widget
//

import AppIntents
import SwiftUI
import WidgetKit

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "AureliaNowPlaying", provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetView(entry: entry)
        }
        .configurationDisplayName("Now Playing")
        .description("The track Aurelia is playing, with transport controls.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryRectangular,
            .accessoryCircular,
            .accessoryInline
        ])
    }
}

struct NowPlayingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
    let entry: NowPlayingEntry

    var body: some View {
        switch family {
        case .systemSmall:
            smallView.widgetURL(AureliaWidgetLink.nowPlaying)
        case .systemMedium:
            mediumView.widgetURL(AureliaWidgetLink.nowPlaying)
        case .accessoryRectangular:
            rectangularView.widgetURL(AureliaWidgetLink.nowPlaying)
        case .accessoryCircular:
            circularView.widgetURL(AureliaWidgetLink.nowPlaying)
        case .accessoryInline:
            inlineView.widgetURL(AureliaWidgetLink.nowPlaying)
        default:
            smallView.widgetURL(AureliaWidgetLink.nowPlaying)
        }
    }

    private var snapshot: NowPlayingSnapshot { entry.snapshot }
    private var accent: Color { WidgetPalette.accent(colorScheme) }

    // MARK: - System families

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkView(image: entry.artwork, accent: accent)
                .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(snapshot.artistName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(WidgetPalette.background(colorScheme), for: .widget)
    }

    private var mediumView: some View {
        HStack(spacing: 14) {
            ArtworkView(image: entry.artwork, accent: accent)

            VStack(alignment: .leading, spacing: 0) {
                Text(snapshot.title)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                Text(snapshot.artistName)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 10)

                ProgressBar(snapshot: snapshot, accent: accent)

                if !snapshot.isPlaceholder {
                    Spacer(minLength: 12)
                    TransportControls(snapshot: snapshot, accent: accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(WidgetPalette.background(colorScheme), for: .widget)
    }

    // MARK: - Accessory families

    private var rectangularView: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label {
                Text(snapshot.title).lineLimit(1)
            } icon: {
                Image(systemName: snapshot.isPlaying ? "waveform" : "pause.fill")
            }
            .font(.headline)

            Text(snapshot.artistName)
                .font(.caption)
                .lineLimit(1)

            if !snapshot.isPlaceholder {
                ProgressBar(snapshot: snapshot, accent: .primary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(.clear, for: .widget)
    }

    private var circularView: some View {
        ZStack {
            AccessoryWidgetBackground()
            if snapshot.isPlaceholder {
                Image(systemName: "music.note")
                    .font(.title3)
            } else if snapshot.isPlaying {
                ProgressView(timerInterval: snapshot.timelineRange, countsDown: false) {
                    Image(systemName: "waveform")
                } currentValueLabel: {
                    Image(systemName: "waveform")
                }
                .progressViewStyle(.circular)
            } else {
                ProgressView(value: snapshot.progress(at: entry.date)) {
                    Image(systemName: "pause.fill")
                } currentValueLabel: {
                    Image(systemName: "pause.fill")
                }
                .progressViewStyle(.circular)
            }
        }
        .containerBackground(.clear, for: .widget)
    }

    private var inlineView: some View {
        Text(snapshot.isPlaceholder ? "Aurelia" : "\(snapshot.title) — \(snapshot.artistName)")
            .containerBackground(.clear, for: .widget)
    }
}

// MARK: - Pieces

struct ArtworkView: View {
    let image: Image?
    let accent: Color

    var body: some View {
        ZStack {
            if let image {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                accent.opacity(0.18)
                Image(systemName: "music.note")
                    .font(.title2)
                    .foregroundStyle(accent)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// A playing track animates its own bar from the snapshot's timeline, so the
/// widget does not need a new entry to show progress moving.
struct ProgressBar: View {
    let snapshot: NowPlayingSnapshot
    let accent: Color

    var body: some View {
        Group {
            if snapshot.isPlaying {
                ProgressView(timerInterval: snapshot.timelineRange, countsDown: false)
                    .labelsHidden()
            } else {
                ProgressView(value: snapshot.progress(at: snapshot.writtenAt))
                    .labelsHidden()
            }
        }
        .progressViewStyle(.linear)
        .tint(accent)
    }
}

struct TransportControls: View {
    let snapshot: NowPlayingSnapshot
    let accent: Color
    var glyphSize: CGFloat = 16

    /// Each button takes an equal share of the row so the three sit evenly
    /// across whatever width they are handed, with tap targets to match.
    var body: some View {
        HStack(spacing: 0) {
            Button(intent: PreviousTrackIntent()) {
                Image(systemName: "backward.fill")
                    .frame(maxWidth: .infinity)
                    .contentShape(.rect)
            }
            Button(intent: TogglePlaybackIntent(isPlaying: snapshot.isPlaying)) {
                Image(systemName: snapshot.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: glyphSize + 4, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .contentShape(.rect)
            }
            Button(intent: NextTrackIntent()) {
                Image(systemName: "forward.fill")
                    .frame(maxWidth: .infinity)
                    .contentShape(.rect)
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: glyphSize))
        .foregroundStyle(accent)
    }
}

enum AureliaWidgetLink {
    static let nowPlaying = URL(string: "aurelia://now-playing")!
}
