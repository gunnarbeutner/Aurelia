//
//  Aurelia_WatchApp.swift
//  Aurelia Watch
//
//  Created by Grafton on 10/17/25.
//

import SwiftUI

@main
struct AureliaWatchApp: App {
    // Initialize Watch Connectivity
    private let watchConnectivity = WatchConnectivityManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
