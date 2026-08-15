//
//  MiniPlayerView.swift
//  Aurelia
//
//  Mini player — aligned with PWA mobile player bar
//

import SwiftUI

enum MiniPlayerLayout {
    static let tabBarClearance: CGFloat = 56
    static let expandedHeight: CGFloat = 62
    static let contentClearance: CGFloat = tabBarClearance + expandedHeight + 8
}

/// Liquid Glass where the OS has it, the previous material chrome elsewhere.
///
/// The glass replaces the old fill rather than sitting behind it: at 0.92 alpha
/// there was nothing left for it to refract, and glass with an opaque backing
/// just reads as a flat panel.
private struct MiniPlayerSurface: ViewModifier {
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            // Clipped as well as shaped, so the progress bar along the top
            // follows the corners instead of squaring them off. Custom glass
            // is decorative by default; marking it interactive keeps controls
            // inside the slab in the native hit-test hierarchy.
            content
                .clipShape(shape)
                .contentShape(shape)
                .glassEffect(.regular.interactive(), in: shape)
        } else {
            content
                .contentShape(shape)
                .background(
                    Color.appMidBackground.opacity(0.92)
                        .background(.ultraThinMaterial)
                )
        }
    }
}

struct MiniPlayerView: View {
    @ObservedObject var playerManager = PlayerManager.shared
    @ObservedObject private var playbackProgress = PlayerManager.shared.playbackProgress
    @Binding var showNowPlaying: Bool

    @ObservedObject var sleepTimer = SleepTimerManager.shared

    var body: some View {
        if let currentTrack = playerManager.currentTrack {
            miniPlayerButton(for: currentTrack)
        }
    }

    // MARK: - Full mini player
    private func miniPlayerButton(for currentTrack: Track) -> some View {
        VStack(spacing: 0) {
            // Progress bar — 2px at top, cyan→pink gradient
            GeometryReader { geo in
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.appAccent, .appSecondary],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geo.size.width * miniPlayerProgress)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.appControlFill)
            }
            .frame(height: 2)
            .animation(.linear(duration: 0.3), value: miniPlayerProgress)

            // Main row
            HStack(spacing: 12) {
                Button(action: presentNowPlaying) {
                    HStack(spacing: 12) {
                        // Artwork
                        miniPlayerArtwork(for: currentTrack)

                        // Track info
                        VStack(alignment: .leading, spacing: 2) {
                            Text(currentTrack.name)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.appText)
                                .lineLimit(1)

                            Text(currentTrack.artistName)
                                .font(.system(size: 13))
                                .foregroundColor(.appTextSecondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        // Sleep timer indicator
                        if sleepTimer.isActive {
                            Image(systemName: "moon.zzz.fill")
                                .font(.caption2)
                                .foregroundColor(.appAccent)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("mini-player")
                .accessibilityLabel("Now playing: \(currentTrack.name) by \(currentTrack.artistName)")
                .accessibilityHint("Tap for full player")

                // Keep transport controls visually consistent and flat.
                Button {
                    playerManager.togglePlayPause()
                } label: {
                    Image(systemName: playerManager.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.appText)
                        .frame(width: 36, height: 44)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityLabel(playerManager.isPlaying ? "Pause" : "Play")
                .accessibilityIdentifier("mini-player-playback")
                .contentTransition(.symbolEffect(.replace))

                Button {
                    playerManager.playNext()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(canPlayNext ? .appText : .appTextMuted)
                        .frame(width: 36, height: 44)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .disabled(!canPlayNext)
                .accessibilityIdentifier("mini-player-next")
                .accessibilityLabel("Next track")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 56)
        }
        .modifier(MiniPlayerSurface())
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: playerManager.currentTrack?.id)
    }

    // MARK: - Helpers

    private func presentNowPlaying() {
        withAnimation(PlayerPresentationMotion.animation) {
            showNowPlaying = true
        }
    }

    private var miniPlayerProgress: Double {
        guard playerManager.duration > 0 else { return 0 }
        return min(max(playbackProgress.currentTime / playerManager.duration, 0), 1)
    }

    private var canPlayNext: Bool {
        playerManager.repeatMode != .off
            || playerManager.currentIndex < playerManager.queue.count - 1
    }

    private func miniPlayerArtwork(for track: Track) -> some View {
        CachedAsyncImage(url: URL(string: track.artworkURL ?? "")) { phase in
            switch phase {
            case .success(let image):
                image.artworkRendering().aspectRatio(contentMode: .fill)
            default:
                ZStack {
                    Color.appElevated
                    Image(systemName: "music.note")
                        .font(.body.weight(.medium))
                        .foregroundColor(.appTextSecondary)
                }
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
        .shadow(color: .appAccent.opacity(0.08), radius: 10, y: 0)
    }
}

// MARK: - Preview
#Preview {
    struct PreviewWrapper: View {
        var body: some View {
            VStack {
                Spacer()
                MiniPlayerView(showNowPlaying: .constant(false))
            }
            .background(Color.appBackground)
        }
    }
    return PreviewWrapper()
}
