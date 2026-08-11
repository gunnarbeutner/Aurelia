//
//  JellyAmpCommands.swift
//  JellyAmp
//
//  Native menu commands and hardware-keyboard shortcuts.
//

import SwiftUI

struct JellyAmpCommandActions {
    let selectedTab: Int
    let isPlayerPresented: Bool
    let selectTab: (Int) -> Void
    let focusSearch: () -> Void
    let togglePlayer: () -> Void
    let dismissPlayer: () -> Void
}

private struct JellyAmpCommandActionsKey: FocusedValueKey {
    typealias Value = JellyAmpCommandActions
}

extension FocusedValues {
    var jellyAmpCommandActions: JellyAmpCommandActions? {
        get { self[JellyAmpCommandActionsKey.self] }
        set { self[JellyAmpCommandActionsKey.self] = newValue }
    }
}

enum JellyAmpShortcuts {
    static let playPause = KeyboardShortcut(.space, modifiers: [])
    static let previousTrack = KeyboardShortcut(.leftArrow, modifiers: [])
    static let nextTrack = KeyboardShortcut(.rightArrow, modifiers: [])
    static let seekBackward = KeyboardShortcut(.leftArrow, modifiers: [.option, .command])
    static let seekForward = KeyboardShortcut(.rightArrow, modifiers: [.option, .command])
    static let togglePlayer = KeyboardShortcut("u", modifiers: [.option, .command])
    static let closePlayer = KeyboardShortcut(.escape, modifiers: [])
    static let focusSearch = KeyboardShortcut("f", modifiers: .command)

    static func tab(_ number: Int) -> KeyboardShortcut {
        KeyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
    }
}

struct JellyAmpCommands: Commands {
    @FocusedValue(\.jellyAmpCommandActions) private var actions
    @ObservedObject private var playerManager = PlayerManager.shared

    var body: some Commands {
        CommandMenu("Playback") {
            Button(playerManager.isPlaying ? "Pause" : "Play") {
                playerManager.togglePlayPause()
            }
            .keyboardShortcut(JellyAmpShortcuts.playPause)
            .disabled(playerManager.currentTrack == nil)

            Divider()

            Button("Previous Track") {
                playerManager.playPrevious()
            }
            .keyboardShortcut(JellyAmpShortcuts.previousTrack)
            .disabled(playerManager.currentTrack == nil)

            Button("Next Track") {
                playerManager.playNext()
            }
            .keyboardShortcut(JellyAmpShortcuts.nextTrack)
            .disabled(playerManager.currentTrack == nil)

            Button("Seek Backward 10 Seconds") {
                playerManager.seek(to: playerManager.currentTime - 10)
            }
            .keyboardShortcut(JellyAmpShortcuts.seekBackward)
            .disabled(playerManager.currentTrack == nil)

            Button("Seek Forward 10 Seconds") {
                playerManager.seek(to: playerManager.currentTime + 10)
            }
            .keyboardShortcut(JellyAmpShortcuts.seekForward)
            .disabled(playerManager.currentTrack == nil)

            Divider()

            Button(playerManager.shuffleEnabled ? "Turn Shuffle Off" : "Turn Shuffle On") {
                playerManager.toggleShuffle()
            }
            .disabled(playerManager.currentTrack == nil)

            Button("Change Repeat Mode") {
                playerManager.toggleRepeatMode()
            }
            .disabled(playerManager.currentTrack == nil)
        }

        CommandMenu("Navigate") {
            Button("Search") {
                actions?.focusSearch()
            }
            .keyboardShortcut(JellyAmpShortcuts.focusSearch)
            .disabled(actions == nil)

            Divider()

            tabButton("Discover", index: 0)
            tabButton("Library", index: 1)
            tabButton("Search Tab", index: 2)
            tabButton("Favorites", index: 3)
            tabButton("Settings", index: 4)

            Divider()

            Button(actions?.isPlayerPresented == true ? "Hide Player" : "Show Player and Queue") {
                actions?.togglePlayer()
            }
            .keyboardShortcut(JellyAmpShortcuts.togglePlayer)
            .disabled(actions == nil || playerManager.currentTrack == nil)

            if actions?.isPlayerPresented == true {
                Button("Close Player") {
                    actions?.dismissPlayer()
                }
                .keyboardShortcut(JellyAmpShortcuts.closePlayer)
            }
        }
    }

    private func tabButton(_ title: String, index: Int) -> some View {
        Button(title) {
            actions?.selectTab(index)
        }
        .keyboardShortcut(JellyAmpShortcuts.tab(index + 1))
        .disabled(actions == nil || actions?.selectedTab == index)
    }
}
