//
//  AureliaControlWidget.swift
//  AureliaWidgets
//
//  Control Center and Action Button play/pause
//

import AppIntents
import SwiftUI
import WidgetKit

// Controls arrived in iOS 18, two releases after the app's deployment target.
@available(iOS 18.0, *)
struct AureliaPlayPauseControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "AureliaPlayPause") {
            ControlWidgetToggle(
                "Play or Pause",
                isOn: SharedContainer.loadSnapshot()?.isPlaying ?? false,
                action: SetPlaybackIntent()
            ) { isPlaying in
                Label(isPlaying ? "Playing" : "Paused", systemImage: isPlaying ? "pause.fill" : "play.fill")
            }
        }
        .displayName("Play or Pause")
        .description("Plays or pauses Aurelia.")
    }
}
