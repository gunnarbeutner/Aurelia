//
//  SettingsView.swift
//  Aurelia
//
//  Settings view with Jellyfin server management and sign out
//

import SwiftUI

private enum SettingsDestination: Hashable {
    case downloads
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

struct SettingsView: View {
    @ObservedObject var jellyfinService = JellyfinService.shared
    @ObservedObject var themeManager = ThemeManager.shared
    @ObservedObject var downloadManager = DownloadManager.shared
    @ObservedObject private var libraryStore = LibraryStore.shared
    @State private var showSignOutConfirmation = false
    @State private var showRebuildConfirmation = false
    @AppStorage("preferredAppearance") private var preferredAppearance = "always_dark"
    @AppStorage("streamingQuality") private var selectedQualityRaw = StreamingQuality.medium.rawValue

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

                    // Offline storage
                    storageSection

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
            Text("This performs a complete Jellyfin metadata download. Routine refreshes will remain incremental.")
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
                        .foregroundColor(.neonCyan)
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
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.appMidBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.white.opacity(0.1), lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var downloadSummary: String {
        let tracks = downloadManager.downloadedTracks.count
        let storage = downloadManager.formatBytes(downloadManager.totalStorageUsed)
        return "\(tracks) \(tracks == 1 ? "track" : "tracks") · \(storage)"
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

            VStack(spacing: 12) {
                ForEach(AppTheme.allCases) { theme in
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            themeManager.currentTheme = theme
                        }
                    } label: {
                        HStack(spacing: 16) {
                            // Theme icon
                            ZStack {
                                Circle()
                                    .fill(themeIconBackground(for: theme))
                                    .frame(width: 44, height: 44)

                                Image(systemName: themeIcon(for: theme))
                                    .font(.title3.weight(.semibold))
                                    .foregroundColor(themeIconColor(for: theme))
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text(theme.displayName)
                                    .font(.appBody)
                                    .foregroundColor(Color.appText)

                                Text(theme.description)
                                    .font(.appCaption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            // Checkmark if selected
                            if themeManager.currentTheme == theme {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.title2)
                                    .foregroundColor(.appAccent)
                            }
                        }
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(themeManager.currentTheme == theme ? Color.appMidBackground : Color.clear)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16)
                                        .stroke(
                                            themeManager.currentTheme == theme ?
                                            LinearGradient(
                                                colors: [Color.appAccent.opacity(0.5), Color.appSecondary.opacity(0.5)],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            ) :
                                            LinearGradient(
                                                colors: [Color.white.opacity(0.1), Color.white.opacity(0.05)],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            ),
                                            lineWidth: themeManager.currentTheme == theme ? 2 : 1
                                        )
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Select \(theme.displayName) theme")
                    .accessibilityAddTraits(themeManager.currentTheme == theme ? .isSelected : [])
                }
            }
            
            // Appearance Setting
            VStack(alignment: .leading, spacing: 12) {
                Text("Color Scheme")
                    .font(.appBody)
                    .foregroundColor(.secondary)
                    .padding(.top, 16)
                
                ForEach(["always_dark", "system"], id: \.self) { appearance in
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
                                            Color.white.opacity(0.1),
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

    // Helper functions for theme icons
    private func themeIcon(for theme: AppTheme) -> String {
        return "bolt.fill"
    }

    private func themeIconColor(for theme: AppTheme) -> Color {
        return .neonCyan
    }

    private func themeIconBackground(for theme: AppTheme) -> Color {
        return .neonCyan.opacity(0.2)
    }
    
    // Helper functions for appearance setting
    private func appearanceIcon(for appearance: String) -> String {
        switch appearance {
        case "always_dark":
            return "moon.fill"
        case "system":
            return "circle.lefthalf.filled"
        default:
            return "moon.fill"
        }
    }
    
    private func appearanceTitle(for appearance: String) -> String {
        switch appearance {
        case "always_dark":
            return "Always Dark"
        case "system":
            return "System"
        default:
            return "Always Dark"
        }
    }
    
    private func appearanceDescription(for appearance: String) -> String {
        switch appearance {
        case "always_dark":
            return "Force dark mode for optimal cypherpunk aesthetic"
        case "system":
            return "Follow system light/dark mode setting"
        default:
            return "Force dark mode for optimal cypherpunk aesthetic"
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
                                        .stroke(selectedQuality == quality ? Color.appAccent.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
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
                    .background(Color.white.opacity(0.1))

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
                    .background(Color.white.opacity(0.1))

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
                            Text(libraryStore.syncMessage ?? "Use only to repair the local cache")
                                .font(.appCaption)
                                .foregroundColor(.appTextSecondary)
                        }
                        Spacer()
                        if libraryStore.isRefreshing {
                            ProgressView(value: libraryStore.syncProgress)
                                .frame(width: 70)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(libraryStore.isRefreshing || !jellyfinService.isAuthenticated)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.appMidBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(
                                LinearGradient(
                                    colors: [Color.appAccent.opacity(0.3), Color.appTertiary.opacity(0.3)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
            )
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

#Preview {
    NavigationStack {
        SettingsView()
    }
}
