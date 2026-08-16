//
//  AureliaApp.swift
//  Aurelia
//
//  Created by Grafton on 10/17/25.
//

import SwiftUI
import AVFoundation
import SDWebImage
import SDWebImageWebPCoder
import UIKit

/// Exists for one callback: when a background download finishes while the app
/// is not running, the system relaunches it and expects to be told when the
/// session's delegate has caught up. Without this the downloads still land, but
/// iOS never learns the app is done and grows reluctant to wake it again.
final class AureliaAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        DownloadManager.shared.backgroundCompletionHandler = completionHandler
    }
}

@main
struct AureliaApp: App {
    @UIApplicationDelegateAdaptor(AureliaAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    #if DEBUG
    private let isPlayerLayoutUITest = ProcessInfo.processInfo.arguments.contains("--ui-test-player-layout")
    private let isAlbumLayoutUITest = ProcessInfo.processInfo.arguments.contains("--ui-test-album-layout")
    private let isDownloadsUITest = ProcessInfo.processInfo.arguments.contains("--ui-test-downloads")
    #endif

    // Initialize Watch Connectivity
    private let watchConnectivity = PhoneConnectivityManager.shared

    init() {
        // libwebp rather than ImageIO. Apple's animated-WebP decoder charges a
        // full decode per frame — measured at 211ms against libwebp's 14ms on
        // the same sleeve — which is a whole core spent on one moving cover.
        SDImageCodersManager.shared.addCoder(SDImageWebPCoder.shared)

        // Has to happen before launching finishes, or the system will not hand
        // the task over when it later decides to run it.
        DownloadBackgroundTask.register()

        // Catalyst draws an AppKit-style focus halo around every bridged text
        // field, which fights the custom field chrome. SwiftUI's
        // .focusEffectDisabled() does not reach the UITextField underneath, so
        // clear the effect on the appearance proxy instead.
        #if targetEnvironment(macCatalyst)
        UITextField.appearance().focusEffect = nil
        UITextView.appearance().focusEffect = nil
        #endif

        // Brand kit fonts: Chakra Petch, Sora, JetBrains Mono (registered via Info.plist)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-player-layout")
            || ProcessInfo.processInfo.arguments.contains("--ui-test-album-layout")
            || ProcessInfo.processInfo.arguments.contains("--ui-test-downloads") {
            cachePlayerLayoutTestArtwork()
            return
        }
        #endif

        // Browsing marks what will not play while the server is unreachable, so
        // both the reachability signal and the downloaded-content index need to
        // be live before the first screen draws.
        NetworkMonitor.shared.onPathRestored = {
            LibrarySyncCoordinator.shared.reconnectEventStream()
        }
        NetworkMonitor.shared.start()
        OfflineAvailability.shared.start()
        KeyboardObserver.shared.start()

        // The download queue holds rule-driven work back on a metered
        // connection, so it needs the reachability signal before it starts
        // draining whatever the last session left behind.
        DownloadManager.shared.start()
        FavoritesOfflineSync.shared.start()
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
                // The path handler stays silent about changes that happened
                // while the app was suspended, so re-probe on the way back in.
                NetworkMonitor.shared.refresh()
                // Likes made on another device land through a sync the app was
                // not awake to observe.
                FavoritesOfflineSync.shared.refresh()
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
