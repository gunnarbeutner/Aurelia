//
//  MiniPlayerView.swift
//  JellyAmp
//
//  Mini player — aligned with PWA mobile player bar
//

import SwiftUI

struct MiniPlayerView: View {
    @ObservedObject var playerManager = PlayerManager.shared
    @ObservedObject private var playbackProgress = PlayerManager.shared.playbackProgress
    @Binding var showNowPlaying: Bool

    @ObservedObject var sleepTimer = SleepTimerManager.shared
    @State private var isCollapsed = false
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        if let currentTrack = playerManager.currentTrack {
            if isCollapsed {
                collapsedStrip(for: currentTrack)
            } else {
                miniPlayerButton(for: currentTrack)
            }
        }
    }

    // MARK: - Collapsed strip (thin bar — swipe down to reach)
    private func collapsedStrip(for currentTrack: Track) -> some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                isCollapsed = false
            }
        } label: {
            VStack(spacing: 0) {
                // Thin progress bar
                GeometryReader { geo in
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [.jellyAmpAccent, .jellyAmpSecondary],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * miniPlayerProgress)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 12)
                .background(Color.white.opacity(0.05))
                .overlay(alignment: .center) {
                    Image(systemName: playerManager.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
        }
        .buttonStyle(.plain)
        .transition(.asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .opacity
        ))
    }

    // MARK: - Full mini player
    private func miniPlayerButton(for currentTrack: Track) -> some View {
        VStack(spacing: 0) {
            // Progress bar — 2px at top, cyan→pink gradient
            GeometryReader { geo in
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.jellyAmpAccent, .jellyAmpSecondary],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geo.size.width * miniPlayerProgress)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.1))
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
                                .foregroundColor(.jellyAmpText)
                                .lineLimit(1)

                            Text(currentTrack.artistName)
                                .font(.system(size: 13))
                                .foregroundColor(.jellyAmpTextSecondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        // Sleep timer indicator
                        if sleepTimer.isActive {
                            Image(systemName: "moon.zzz.fill")
                                .font(.caption2)
                                .foregroundColor(.jellyAmpAccent)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("mini-player")
                .accessibilityLabel("Now playing: \(currentTrack.name) by \(currentTrack.artistName)")
                .accessibilityHint("Tap for full player")

                // Play/pause — solid gradient circle like PWA
                Button {
                    playerManager.togglePlayPause()
                } label: {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [.jellyAmpAccent, .jellyAmpSecondary],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 44, height: 44)

                        Image(systemName: playerManager.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.black)
                            .offset(x: playerManager.isPlaying ? 0 : 1)
                    }
                }
                .accessibilityLabel(playerManager.isPlaying ? "Pause" : "Play")
                .contentTransition(.symbolEffect(.replace))

                Button {
                    playerManager.playNext()
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(canPlayNext ? .white.opacity(0.8) : .white.opacity(0.25))
                        .frame(width: 36, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(!canPlayNext)
                .accessibilityIdentifier("mini-player-next")
                .accessibilityLabel("Next track")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 56)
        }
        .background(
            Color(hex: "0C0C12").opacity(0.88)
                .background(.ultraThinMaterial)
        )
        .offset(x: max(0, dragOffset))
        .simultaneousGesture(
            DragGesture(minimumDistance: 15)
                .onChanged { value in
                    if value.translation.width > 0 {
                        dragOffset = value.translation.width * 0.5
                    }
                }
                .onEnded { value in
                    if value.translation.width > 60 {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            isCollapsed = true
                            dragOffset = 0
                        }
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            dragOffset = 0
                        }
                    }
                }
        )
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
                image.resizable().aspectRatio(contentMode: .fill)
            default:
                ZStack {
                    Color.jellyAmpElevated
                    Image(systemName: "music.note")
                        .font(.body.weight(.medium))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
        .shadow(color: .jellyAmpAccent.opacity(0.08), radius: 10, y: 0)
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
            .background(Color.jellyAmpBackground)
        }
    }
    return PreviewWrapper()
}
