//
//  JellyAmpApp.swift
//  JellyAmp
//
//  Created by Grafton on 10/17/25.
//

import SwiftUI
import AVFoundation
import UserNotifications
import UIKit

@main
struct JellyAmpApp: App {
    @Environment(\.scenePhase) private var scenePhase

    #if DEBUG
    private let isPlayerLayoutUITest = ProcessInfo.processInfo.arguments.contains("--ui-test-player-layout")
    private let isAlbumLayoutUITest = ProcessInfo.processInfo.arguments.contains("--ui-test-album-layout")
    #endif

    // Initialize Watch Connectivity
    private let watchConnectivity = PhoneConnectivityManager.shared

    init() {
        // Brand kit fonts: Chakra Petch, Sora, JetBrains Mono (registered via Info.plist)
        // Request notification permissions for download completion alerts
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-player-layout")
            || ProcessInfo.processInfo.arguments.contains("--ui-test-album-layout") {
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
            } else {
                ContentView()
            }
            #else
            ContentView()
            #endif
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

        case .inactive:
            // App is transitioning (e.g., control center, notification)
            print("🟡 App became inactive")

        case .background:
            // App went to background - CRITICAL for background audio
            print("🔵 App entered background - Audio should continue playing")

            // Save playback state so we can restore on next launch
            PlayerManager.shared.savePlaybackState()

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
