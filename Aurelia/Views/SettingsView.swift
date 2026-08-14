//
//  SettingsView.swift
//  Aurelia
//
//  Settings view with Jellyfin server management and sign out
//

import SwiftUI

private enum SettingsDestination: Hashable {
    case downloads
    case favoritesOffline
}

enum StreamingQuality: String, CaseIterable, Identifiable {
    case low = "low"
    case medium = "medium"
    case high = "high"
    case original = "original"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .original: return "Original"
        }
    }

    var description: String {
        switch self {
        case .low: return "96 kbps — saves data"
        case .medium: return "192 kbps — balanced"
        case .high: return "320 kbps — high quality"
        case .original: return "Direct stream — best quality, more data"
        }
    }

    var bitrate: Int {
        switch self {
        case .low: return 96
        case .medium: return 192
        case .high: return 320
        case .original: return 0
        }
    }
}

private enum AureliaSyncSettingsState: Equatable {
    case checking
    case ready(String)
    case missingCanInstall
    case missingNeedsAdministrator
    case installing
    case restartRequired
    case unavailable(String)
}

struct SettingsView: View {
    @ObservedObject var jellyfinService = JellyfinService.shared
    @ObservedObject var downloadManager = DownloadManager.shared
    @ObservedObject private var playerManager = PlayerManager.shared
    @ObservedObject private var libraryStore = LibraryStore.shared
    @ObservedObject private var favoritesOffline = FavoritesOfflineSync.shared
    @State private var showSignOutConfirmation = false
    @State private var showRebuildConfirmation = false
    @State private var showLibrarySyncError = false
    @AppStorage("preferredAppearance") private var preferredAppearance: AppearancePreference = .system
    @AppStorage("streamingQuality") private var selectedQualityRaw = StreamingQuality.medium.rawValue
    @State private var audioMuseAvailability: AudioMuseAvailability = .checking
    @State private var aureliaSyncState: AureliaSyncSettingsState = .checking
    /// Carried across readings so a single failed request cannot report a
    /// working plugin as missing.
    @State private var audioMusePresenceConfirmed = false

    private var selectedQuality: StreamingQuality {
        get { StreamingQuality(rawValue: selectedQualityRaw) ?? .medium }
    }
    private func setSelectedQuality(_ quality: StreamingQuality) {
        selectedQualityRaw = quality.rawValue
    }

    var body: some View {
        ZStack {
            // Dark background
            Color.appBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    // Header with app icon/logo
                    headerSection

                    // Theme Selector
                    themeSection

                    // Streaming Quality
                    streamingQualitySection

                    // Queue continuation
                    autoplaySection

                    // Offline storage
                    storageSection

                    // Library sync — the single place sync is observed and started
                    librarySyncSection

                    aureliaSyncSection

                    // Server Info Section
                    serverInfoSection

                    // Danger Zone
                    signOutSection

                    Spacer(minLength: 40)
                }
                .padding()
            }
        }
        .rootTabNavigationTitle("Settings")
        .navigationDestination(for: SettingsDestination.self) { destination in
            switch destination {
            case .downloads:
                DownloadsView()
            case .favoritesOffline:
                FavoritesOfflineView()
            }
        }
        .confirmationDialog("Sign Out", isPresented: $showSignOutConfirmation) {
            Button("Sign Out", role: .destructive) {
                jellyfinService.signOut()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to sign out? You'll need to reconnect to your Jellyfin server.")
        }
        .confirmationDialog("Rebuild Local Library", isPresented: $showRebuildConfirmation) {
            Button("Rebuild", role: .destructive) {
                Task { await libraryStore.rebuild() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This downloads a fresh copy of your library. Your current library remains available until the rebuild finishes.")
        }
        .alert("Library Update Failed", isPresented: $showLibrarySyncError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(libraryStore.errorMessage ?? "The library could not be updated.")
        }
        .task { await checkAureliaSync() }
    }

    private var aureliaSyncSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Aurelia Sync")
                .font(.appHeadline)
                .foregroundColor(.appAccent)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: aureliaSyncStateIcon)
                        .foregroundColor(aureliaSyncStateColor)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(aureliaSyncStateTitle)
                            .font(.appBody)
                            .foregroundColor(.appText)
                        Text(aureliaSyncStateDetail)
                            .font(.appCaption)
                            .foregroundColor(.appTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if aureliaSyncState == .checking || aureliaSyncState == .installing {
                        ProgressView().tint(.appAccent)
                    }
                }

                if aureliaSyncState == .missingCanInstall {
                    Button("Install Aurelia Sync") {
                        Task { await installAureliaSync() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.appAccent)
                } else if aureliaSyncState == .restartRequired {
                    Button("Check Again") { Task { await checkAureliaSync() } }
                        .buttonStyle(.bordered)
                        .tint(.appAccent)
                }
            }
            .settingsCard()
        }
    }

    private var aureliaSyncStateTitle: String {
        switch aureliaSyncState {
        case .checking: "Checking plugin…"
        case .ready(let version): "Ready · \(version)"
        case .missingCanInstall: "Plugin required"
        case .missingNeedsAdministrator: "Plugin required"
        case .installing: "Installing…"
        case .restartRequired: "Server restart required"
        case .unavailable: "Plugin unavailable"
        }
    }

    private var aureliaSyncStateDetail: String {
        switch aureliaSyncState {
        case .checking: "Checking the required sync service."
        case .ready: "Aurelia Sync keeps your local library up to date."
        case .missingCanInstall: "Install the plugin from Aurelia's Jellyfin repository."
        case .missingNeedsAdministrator: "Ask a Jellyfin administrator to install Aurelia Sync."
        case .installing: "Adding the repository and installing the plugin package."
        case .restartRequired: "Restart Jellyfin, then check again."
        case .unavailable(let message): message
        }
    }

    private var aureliaSyncStateIcon: String {
        switch aureliaSyncState {
        case .ready: "checkmark.circle.fill"
        case .missingCanInstall, .missingNeedsAdministrator, .unavailable: "exclamationmark.triangle"
        case .restartRequired: "power"
        case .checking, .installing: "arrow.triangle.2.circlepath"
        }
    }

    private var aureliaSyncStateColor: Color {
        switch aureliaSyncState {
        case .ready: .appSuccess
        case .missingCanInstall, .missingNeedsAdministrator, .unavailable: .appError
        default: .appAccent
        }
    }

    private func checkAureliaSync() async {
        guard jellyfinService.isAuthenticated else { return }
        aureliaSyncState = .checking
        do {
            let status = try await AureliaSyncClient.shared.status()
            aureliaSyncState = status.enabled && status.healthy
                ? .ready(status.pluginVersion)
                : .unavailable(status.healthDetail ?? "The plugin is disabled or unhealthy.")
        } catch AureliaSyncError.required {
            do {
                aureliaSyncState = try await AureliaSyncPluginManager.shared.currentUserIsAdministrator()
                    ? .missingCanInstall : .missingNeedsAdministrator
            } catch {
                aureliaSyncState = .unavailable(error.localizedDescription)
            }
        } catch {
            aureliaSyncState = .unavailable(error.localizedDescription)
        }
    }

    private func installAureliaSync() async {
        aureliaSyncState = .installing
        do {
            try await AureliaSyncPluginManager.shared.install()
            aureliaSyncState = .restartRequired
        } catch {
            aureliaSyncState = .unavailable(error.localizedDescription)
        }
    }

    // MARK: - Library Sync Section

    /// Sync progress is reported only here. The browsing screens deliberately
    /// stay free of sync chrome, so this is where a sync is watched and where a
    /// manual one is started (pull-to-refresh still works in the tabs).
    private var librarySyncSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Library Sync")
                .font(.appHeadline)
                .foregroundColor(.appAccent)

            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: libraryStore.isRefreshing
                          ? "arrow.triangle.2.circlepath"
                          : libraryStore.errorMessage == nil ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundColor(libraryStore.isRefreshing
                                         ? .appAccent
                                         : libraryStore.errorMessage == nil ? .appSuccess : .appError)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(libraryStore.isRefreshing
                             ? "Updating library"
                             : libraryStore.errorMessage == nil ? "Up to date" : "Update failed")
                            .font(.appBody)
                            .foregroundColor(.appText)
                        Text(libraryStore.isRefreshing
                             ? (libraryStore.syncMessage ?? "Preparing library sync…")
                             : (libraryStore.errorMessage ?? "Updates automatically"))
                            .font(.appCaption)
                            .foregroundColor(.appTextSecondary)
                            .lineLimit(libraryStore.errorMessage == nil ? 1 : 2)
                    }

                    Spacer()

                    if libraryStore.isRefreshing, let progress = libraryStore.syncProgress {
                        Text("\(Int(progress * 100))%")
                            .font(.appMono)
                            .foregroundColor(.appTextMuted)
                    }
                }

                if libraryStore.errorMessage != nil {
                    Button("Show Details") { showLibrarySyncError = true }
                        .font(.appSubheadline)
                        .foregroundColor(.appAccent)
                        .buttonStyle(.plain)
                }

                if libraryStore.isRefreshing {
                    ProgressView(value: libraryStore.syncProgress)
                        .tint(.appAccent)
                }

                Divider()
                    .background(Color.appControlFill)

                Button {
                    Task { await libraryStore.refresh(trigger: .manual) }
                } label: {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                            .foregroundColor(.appAccent)
                            .frame(width: 24)
                        Text("Sync Now")
                            .font(.appBody)
                            .foregroundColor(.appText)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .disabled(libraryStore.isRefreshing || !jellyfinService.isAuthenticated)
                .accessibilityLabel("Sync now")

                Divider()
                    .background(Color.appControlFill)

                Button {
                    showRebuildConfirmation = true
                } label: {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundColor(.appTertiary)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Rebuild Local Library")
                                .font(.appBody)
                                .foregroundColor(.appText)
                            Text("Use only to repair the local cache")
                                .font(.appCaption)
                                .foregroundColor(.appTextSecondary)
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .disabled(libraryStore.isRefreshing || !jellyfinService.isAuthenticated)
            }
            .settingsCard()
        }
    }

    // MARK: - Offline Storage Section

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Offline Storage")
                .font(.appHeadline)
                .foregroundColor(.appAccent)

            NavigationLink(value: SettingsDestination.downloads) {
                HStack(spacing: 14) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title2)
                        .foregroundColor(.appAccent)
                        .frame(width: 34)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Downloads")
                            .font(.appBody)
                            .foregroundColor(.appText)
                        Text(downloadSummary)
                            .font(.appCaption)
                            .foregroundColor(.appTextSecondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.appTextMuted)
                }
                .settingsCard()
            }
            .buttonStyle(.plain)

            NavigationLink(value: SettingsDestination.favoritesOffline) {
                HStack(spacing: 14) {
                    Image(systemName: "heart.circle.fill")
                        .font(.title2)
                        .foregroundColor(.appAccent)
                        .frame(width: 34)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Favorites Offline")
                            .font(.appBody)
                            .foregroundColor(.appText)
                        Text(favoritesOfflineSummary)
                            .font(.appCaption)
                            .foregroundColor(.appTextSecondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.appTextMuted)
                }
                .settingsCard()
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings-favorites-offline")
        }
    }

    private var downloadSummary: String {
        let tracks = downloadManager.downloadedTracks.count
        let storage = downloadManager.formatBytes(downloadManager.totalStorageUsed)
        return "\(tracks) \(tracks == 1 ? "track" : "tracks") · \(storage)"
    }

    private var favoritesOfflineSummary: String {
        switch favoritesOffline.status {
        case .off:
            return "Off"
        case .unavailable:
            return "On · library unavailable"
        case .upToDate(let count):
            return count == 0 ? "On · nothing liked yet" : "On · \(count) tracks · up to date"
        case .syncing(let completed, let total):
            return "On · downloading \(completed) of \(total)"
        case .waitingForWiFi(let remaining):
            return "On · waiting for Wi-Fi · \(remaining) left"
        case .paused(let completed, let total):
            return "On · paused at \(completed) of \(total)"
        case .failed(_, _, let failures):
            return "On · \(failures) failed"
        }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(spacing: 12) {
            // App Icon
            Image("AppIcon_Display")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: Color.appAccent.opacity(0.3), radius: 10, y: 4)

            Text("Aurelia")
                .font(.appTitle)
                .foregroundColor(Color.appText)

            Text("Version 1.1 (8)")
                .font(.appMono)
                .foregroundColor(.secondary)

            Link(destination: URL(string: "https://github.com/satsdisco/JellyAmp")!) {
                Text("Forked from JellyAmp")
                    .font(.appCaption)
                    .foregroundColor(.appTextMuted)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    // MARK: - Theme Section

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Appearance")
                .font(.appHeadline)
                .foregroundColor(.appAccent)

            VStack(alignment: .leading, spacing: 12) {
                Text("Color Scheme")
                    .font(.appBody)
                    .foregroundColor(.secondary)

                ForEach(AppearancePreference.allCases) { appearance in
                    Button {
                        preferredAppearance = appearance
                    } label: {
                        HStack {
                            Image(systemName: appearanceIcon(for: appearance))
                                .font(.title3)
                                .foregroundColor(.appText)
                                .frame(width: 24)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(appearanceTitle(for: appearance))
                                    .font(.appBody)
                                    .foregroundColor(.appText)
                                
                                Text(appearanceDescription(for: appearance))
                                    .font(.appCaption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            if preferredAppearance == appearance {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.title2)
                                    .foregroundColor(.appAccent)
                            }
                        }
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(preferredAppearance == appearance ? Color.appMidBackground : Color.clear)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(
                                            preferredAppearance == appearance ?
                                            Color.appAccent.opacity(0.5) :
                                            Color.appBorder,
                                            lineWidth: 1
                                        )
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // Helper functions for appearance setting
    private func appearanceIcon(for appearance: AppearancePreference) -> String {
        switch appearance {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }
    
    private func appearanceTitle(for appearance: AppearancePreference) -> String {
        appearance.displayName
    }
    
    private func appearanceDescription(for appearance: AppearancePreference) -> String {
        switch appearance {
        case .system: return "Follow the system appearance"
        case .light: return "Always use the light appearance"
        case .dark: return "Always use the dark appearance"
        }
    }

    // MARK: - Streaming Quality Section
    private var streamingQualitySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Streaming")
                .font(.appHeadline)
                .foregroundColor(.appAccent)

            VStack(spacing: 8) {
                ForEach(StreamingQuality.allCases) { quality in
                    Button {
                        setSelectedQuality(quality)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(quality.displayName)
                                    .font(.appBody)
                                    .foregroundColor(Color.appText)
                                Text(quality.description)
                                    .font(.appCaption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if selectedQuality == quality {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.title2)
                                    .foregroundColor(.appAccent)
                            }
                        }
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(selectedQuality == quality ? Color.appMidBackground : Color.clear)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(selectedQuality == quality ? Color.appAccent.opacity(0.5) : Color.appControlFill, lineWidth: 1)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Autoplay Section

    private var autoplaySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Playback")
                .font(.appHeadline)
                .foregroundColor(.appAccent)

            Toggle(isOn: $playerManager.continuePlayingSimilarMusic) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Continue Playing Similar Music")
                        .font(.appBody)
                        .foregroundColor(.appText)
                    Text("Use AudioMuse to keep playing after your queue ends")
                        .font(.appCaption)
                        .foregroundColor(.appTextSecondary)
                }
            }
            // A filled switch is a far larger field of colour than the accent
            // carries anywhere else, and at full strength against a near-black
            // card it shouts louder than the setting it describes.
            .tint(.appAccentMuted)
            .settingsCard()
            .accessibilityIdentifier("continue-playing-similar-music")
        }
    }

    // MARK: - Server Info Section

    private var serverInfoSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Server")
                .font(.appHeadline)
                .foregroundColor(.appAccent)

            VStack(alignment: .leading, spacing: 12) {
                // Server URL
                HStack {
                    Image(systemName: "server.rack")
                        .foregroundColor(.appTertiary)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Server URL")
                            .font(.appBody)
                            .foregroundColor(.secondary)

                        Text(jellyfinService.baseURL.isEmpty ? "Not configured" : jellyfinService.baseURL)
                            .font(.appMono)
                            .foregroundColor(Color.appText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()
                }

                Divider()
                    .background(Color.appControlFill)

                // Connection Status
                HStack {
                    Image(systemName: jellyfinService.isAuthenticated ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(jellyfinService.isAuthenticated ? .appSuccess : .appSecondary)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Status")
                            .font(.appBody)
                            .foregroundColor(.secondary)

                        Text(jellyfinService.isAuthenticated ? "Connected" : "Disconnected")
                            .font(.appMono)
                            .foregroundColor(jellyfinService.isAuthenticated ? .appSuccess : .appSecondary)
                    }

                    Spacer()
                }

                Divider()
                    .background(Color.appControlFill)

                audioMuseRow
            }
            .settingsCard()
        }
        .task {
            // Whether the plugin is installed is a standing fact about the
            // server, so it belongs here rather than nagging from Discover.
            // One reading is enough for that — but an analysis in progress is
            // live, so it keeps asking until the run finishes. The task is torn
            // down with the view, so nothing polls in the background.
            while !Task.isCancelled {
                let reading = await AudioMuseStatusProbe.read(
                    from: jellyfinService,
                    presenceAlreadyConfirmed: audioMusePresenceConfirmed
                )
                audioMusePresenceConfirmed = reading.confirmedPresence
                // Nil means the request was cancelled; the previous answer is
                // better than replacing it with a guess.
                if let resolved = reading.availability {
                    audioMuseAvailability = resolved
                }
                guard case .analyzing = audioMuseAvailability else { return }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var audioMuseRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: audioMuseSymbol)
                    .foregroundColor(audioMuseColor)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text("AudioMuse-AI")
                        .font(.appBody)
                        .foregroundColor(.secondary)

                    Text(audioMuseDescription)
                        .font(.appMono)
                        .foregroundColor(audioMuseColor)
                        .lineLimit(2)
                }

                Spacer()

                if case .analyzing(let task) = audioMuseAvailability,
                   let progress = task.progressFraction {
                    Text("\(Int(progress * 100))%")
                        .font(.appMono)
                        .foregroundColor(.appTextMuted)
                }
            }

            if case .analyzing(let task) = audioMuseAvailability {
                if let progress = task.progressFraction {
                    ProgressView(value: progress)
                        .tint(.appAccent)
                } else {
                    ProgressView()
                        .tint(.appAccent)
                }
            }
        }
        .accessibilityIdentifier("settings-audiomuse-status")
    }

    private var audioMuseSymbol: String {
        switch audioMuseAvailability {
        case .checking: return "waveform.path.ecg"
        case .analyzing: return "waveform.badge.magnifyingglass"
        case .ready: return "checkmark.circle.fill"
        case .unavailable: return "exclamationmark.triangle.fill"
        case .notInstalled: return "xmark.circle.fill"
        }
    }

    private var audioMuseColor: Color {
        switch audioMuseAvailability {
        case .checking, .notInstalled: return .appTextSecondary
        case .analyzing: return .appAccent
        case .ready: return .appSuccess
        case .unavailable: return .appSecondary
        }
    }

    private var audioMuseDescription: String {
        switch audioMuseAvailability {
        case .checking:
            return "Checking…"
        case .analyzing(let task):
            // The server's own words when it has any — "analyzing" alone says
            // nothing about how far along a long run is.
            return task.message ?? "Analyzing your library"
        case .ready(let version):
            return "Connected (\(version))"
        case .unavailable:
            return "Installed but not responding"
        case .notInstalled:
            // Named as a capability rather than a fault: not everyone wants it.
            return "Not installed — required for Daily Mixes"
        }
    }

    // MARK: - Sign Out Section

    private var signOutSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Danger Zone")
                .font(.appHeadline)
                .foregroundColor(.red)

            Button {
                showSignOutConfirmation = true
            } label: {
                HStack {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                    Text("Sign Out")
                        .font(.appHeadline)
                    Spacer()
                }
                .foregroundColor(Color.appText)
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(
                            LinearGradient(
                                colors: [.red.opacity(0.2), .red.opacity(0.1)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(
                                    LinearGradient(
                                        colors: [.red.opacity(0.8), .red.opacity(0.5)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 2
                                )
                        )
                )
            }
            .accessibilityLabel("Sign out of account")
        }
    }
}

// MARK: - Preview

extension View {
    /// The card treatment every Settings section shares. Defined once so the
    /// sections cannot drift apart in padding, fill or outline.
    func settingsCard() -> some View {
        padding()
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.appMidBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.appAccent.opacity(0.3),
                                        Color.appTertiary.opacity(0.3)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
            )
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}
