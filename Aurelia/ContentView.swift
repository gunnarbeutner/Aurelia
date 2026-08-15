//
//  ContentView.swift
//  Aurelia
//
//  Root view that shows onboarding or main app based on authentication
//

import SwiftUI
import UIKit

struct ContentView: View {
    @ObservedObject var jellyfinService = JellyfinService.shared
    @AppStorage("preferredAppearance") private var preferredAppearance: AppearancePreference = .system
    /// Set once a server has proven it can sync, and cleared on sign out.
    ///
    /// Checking on every launch costs a round trip before anything draws, and
    /// blocks the app entirely when the server is unreachable — which is
    /// exactly when downloaded music is the point. A plugin that breaks later
    /// surfaces as a sync error, with its health and an install button in
    /// Settings.
    @AppStorage("hasCompletedSyncSetup") private var hasConfirmedSyncPlugin = false


    var body: some View {
        Group {
            if jellyfinService.isAuthenticated && !hasConfirmedSyncPlugin {
                // Signing in is not enough on its own: without the sync plugin
                // the server has no library to give, and finding that out as a
                // failed sync explains none of it.
                SyncSetupView { hasConfirmedSyncPlugin = true }
            } else if jellyfinService.isAuthenticated {
                // User is authenticated - show main app
                MainTabView()
                    .onAppear {
                        // Restore last playback state on launch (queue, track, position)
                        PlayerManager.shared.restorePlaybackState()
                    }
                    .task(id: jellyfinService.libraryScope) {
                        #if DEBUG
                        if ProcessInfo.processInfo.arguments.contains("--benchmark-full-sync") {
                            await LibraryStore.shared.rebuild()
                            return
                        }
                        #endif
                        await LibraryStore.shared.activate()
                    }
            } else {
                // User not authenticated - show onboarding
                OnboardingView()
            }
        }
        .preferredColorScheme(preferredAppearance.colorScheme)
        .onAppear {
            applyWindowAppearance()
        }
        .onChange(of: preferredAppearance) { _, _ in
            applyWindowAppearance()
        }
    }

    private func applyWindowAppearance() {
        let interfaceStyle: UIUserInterfaceStyle
        switch preferredAppearance {
        case .system: interfaceStyle = .unspecified
        case .light: interfaceStyle = .light
        case .dark: interfaceStyle = .dark
        }

        // Catalyst context menus and other native window chrome are hosted by
        // AppKit, outside the UIKit window hierarchy. Keep the application-level
        // appearance in sync so those surfaces do not remain dark in Light mode.
        #if targetEnvironment(macCatalyst)
        applyMacApplicationAppearance()
        #endif

        for case let windowScene as UIWindowScene in UIApplication.shared.connectedScenes {
            #if targetEnvironment(macCatalyst)
            windowScene.titlebar?.titleVisibility = .hidden
            #endif
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = interfaceStyle
            }
        }
    }

    #if targetEnvironment(macCatalyst)
    private func applyMacApplicationAppearance() {
        guard
            let applicationClass = NSClassFromString("NSApplication") as? NSObject.Type,
            let application = applicationClass
                .perform(NSSelectorFromString("sharedApplication"))?
                .takeUnretainedValue() as? NSObject
        else { return }

        let appearanceName: String?
        switch preferredAppearance {
        case .system: appearanceName = nil
        case .light: appearanceName = "NSAppearanceNameAqua"
        case .dark: appearanceName = "NSAppearanceNameDarkAqua"
        }

        guard let appearanceName else {
            application.setValue(nil, forKey: "appearance")
            return
        }

        guard
            let appearanceClass = NSClassFromString("NSAppearance") as? NSObject.Type,
            let appearance = appearanceClass
                .perform(NSSelectorFromString("appearanceNamed:"), with: appearanceName)?
                .takeUnretainedValue()
        else { return }

        application.setValue(appearance, forKey: "appearance")
    }
    #endif
}

#Preview {
    ContentView()
}
