//
//  AureliaApp.swift
//  Aurelia
//
//  Created by Grafton on 10/17/25.
//

import SwiftUI
import AVFoundation
import UserNotifications
import UIKit

@main
struct AureliaApp: App {
    @Environment(\.scenePhase) private var scenePhase

    #if DEBUG
    private let isPlayerLayoutUITest = ProcessInfo.processInfo.arguments.contains("--ui-test-player-layout")
    private let isAlbumLayoutUITest = ProcessInfo.processInfo.arguments.contains("--ui-test-album-layout")
    private let isDownloadsUITest = ProcessInfo.processInfo.arguments.contains("--ui-test-downloads")
    #endif

    // Initialize Watch Connectivity
    private let watchConnectivity = PhoneConnectivityManager.shared

    init() {
        // Catalyst draws an AppKit-style focus halo around every bridged text
        // field, which fights the custom field chrome. SwiftUI's
        // .focusEffectDisabled() does not reach the UITextField underneath, so
        // clear the effect on the appearance proxy instead.
        #if targetEnvironment(macCatalyst)
        UITextField.appearance().focusEffect = nil
        UITextView.appearance().focusEffect = nil
        #endif

        // Brand kit fonts: Chakra Petch, Sora, JetBrains Mono (registered via Info.plist)
        // Request notification permissions for download completion alerts
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-player-layout")
            || ProcessInfo.processInfo.arguments.contains("--ui-test-album-layout")
            || ProcessInfo.processInfo.arguments.contains("--ui-test-downloads") {
            cachePlayerLayoutTestArtwork()
            return
        }
        #endif
        requestNotificationPermissions()
    }

    #if DEBUG
    private func cachePlayerLayoutTestArtwork() {
        guard let url = URL(
            string: "https://ui-test.invalid/Items/ui-layout-album/Images/Primary?maxWidth=300&tag=ui-test"
        ) else { return }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 600)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 600))
        }
        ImageCache.shared.cacheMemoryImage(image, for: url)
    }
    #endif

    private func requestNotificationPermissions() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                print("✅ Notification permission granted")
            } else if let error = error {
                print("❌ Notification permission error: \(error.localizedDescription)")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if isPlayerLayoutUITest {
                MainTabView()
            } else if isAlbumLayoutUITest {
                AlbumDetailLayoutUITestHost()
            } else if isDownloadsUITest {
                NavigationStack {
                    DownloadsView()
                }
            } else {
                ContentView()
            }
            #else
            ContentView()
            #endif
        }
        .commands {
            AureliaCommands()
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            handleScenePhaseChange(oldPhase: oldPhase, newPhase: newPhase)
        }
    }

    /// Handle scene phase changes to maintain background audio
    private func handleScenePhaseChange(oldPhase: ScenePhase, newPhase: ScenePhase) {
        switch newPhase {
        case .active:
            // App became active (foreground)
            print("🟢 App became active")
            Task { @MainActor in
                LibrarySyncCoordinator.shared.startEventMonitoring()
            }

        case .inactive:
            // App is transitioning (e.g., control center, notification)
            print("🟡 App became inactive")

        case .background:
            // App went to background - CRITICAL for background audio
            print("🔵 App entered background - Audio should continue playing")
            Task { @MainActor in
                LibrarySyncCoordinator.shared.stopEventMonitoring()
            }

            // Save playback state so we can restore on next launch
            PlayerManager.shared.savePlaybackState(synchronously: true)

            // Ensure audio session remains active
            do {
                let audioSession = AVAudioSession.sharedInstance()
                try audioSession.setActive(true)
                print("✅ Audio session kept active in background")
            } catch let error as NSError {
                print("❌ Failed to keep audio session active in background: \(error.localizedDescription) (code: \(error.code))")
            }

        @unknown default:
            break
        }
    }
}
