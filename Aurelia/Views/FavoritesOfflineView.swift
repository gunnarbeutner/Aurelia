//
//  FavoritesOfflineView.swift
//  Aurelia
//
//  Settings screen for the "Keep Favorites Offline" rule.
//
//  Everything about the feature lives here rather than on the Favorites tab:
//  it is a standing preference with a storage cost, and the browsing screens
//  stay free of sync chrome.
//

import SwiftUI

struct FavoritesOfflineView: View {
    @ObservedObject private var sync = FavoritesOfflineSync.shared
    @ObservedObject private var downloadManager = DownloadManager.shared

    @State private var showStartSheet = false
    @State private var showStopDialog = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                statusSection

                if sync.isEnabled {
                    scopeSection
                    networkSection
                    stopSection
                }

                Color.clear.frame(height: 80)
            }
            .padding()
        }
        .background(Color.appBackground.ignoresSafeArea())
        .navigationTitle("Favorites Offline")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showStartSheet) {
            FavoritesOfflineStartSheet {
                sync.isEnabled = true
            }
        }
        .confirmationDialog("Turn Off Favorites Offline", isPresented: $showStopDialog) {
            Button("Keep Downloads") {
                sync.disable(removingDownloads: false)
            }
            Button("Delete Downloads", role: .destructive) {
                sync.disable(removingDownloads: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Keeping them turns these into ordinary downloads you manage yourself.")
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keep Favorites Offline")
                .font(.appHeadline)
                .foregroundColor(.appAccent)

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: statusIcon)
                        .foregroundColor(statusColor)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(statusTitle)
                            .font(.appBody)
                            .foregroundColor(.appText)
                        Text(statusDetail)
                            .font(.appCaption)
                            .foregroundColor(.appTextSecondary)
                            .lineLimit(2)
                    }

                    Spacer()
                }
                .accessibilityIdentifier("favorites-offline-status")

                if let progress = statusProgress {
                    ProgressView(value: progress)
                        .tint(.appAccent)
                }

                if !sync.isEnabled {
                    Divider().background(Color.appControlFill)

                    Button {
                        showStartSheet = true
                    } label: {
                        HStack {
                            Image(systemName: "arrow.down.circle")
                                .foregroundColor(.appAccent)
                                .frame(width: 24)
                            Text("Turn On")
                                .font(.appBody)
                                .foregroundColor(.appText)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("favorites-offline-turn-on")
                }

                if sync.isEnabled, isWorking {
                    Divider().background(Color.appControlFill)

                    Button {
                        if downloadManager.isPaused {
                            downloadManager.resume()
                        } else {
                            downloadManager.pause()
                        }
                    } label: {
                        HStack {
                            Image(systemName: downloadManager.isPaused ? "play.circle" : "pause.circle")
                                .foregroundColor(.appAccent)
                                .frame(width: 24)
                            Text(downloadManager.isPaused ? "Resume" : "Pause")
                                .font(.appBody)
                                .foregroundColor(.appText)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("favorites-offline-pause")
                }

                if failureCount > 0 {
                    Divider().background(Color.appControlFill)

                    Button {
                        downloadManager.retryFailedDownloads()
                    } label: {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                                .foregroundColor(.appWarning)
                                .frame(width: 24)
                            Text("Retry \(failureCount) Failed")
                                .font(.appBody)
                                .foregroundColor(.appText)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("favorites-offline-retry")
                }
            }
            .settingsCard()
        }
    }

    // MARK: - Scope

    private var scopeSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What to Keep")
                .font(.appHeadline)
                .foregroundColor(.appAccent)

            VStack(spacing: 14) {
                scopeToggle(
                    title: "Liked Tracks",
                    kind: .tracks,
                    isOn: $sync.scope.includesTracks
                )

                Divider().background(Color.appControlFill)

                scopeToggle(
                    title: "Liked Albums",
                    kind: .albums,
                    isOn: $sync.scope.includesAlbums
                )

                Divider().background(Color.appControlFill)

                scopeToggle(
                    title: "Liked Artists",
                    kind: .artists,
                    isOn: $sync.scope.includesArtists,
                    caution: "A liked artist means their whole discography."
                )
            }
            .settingsCard()
        }
        .task {
            await sync.loadPreviews()
        }
    }

    private func scopeToggle(
        title: String,
        kind: FavoritesOfflineScopePreview.Kind,
        isOn: Binding<Bool>,
        caution: String? = nil
    ) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.appBody)
                    .foregroundColor(.appText)
                Text(previewDetail(for: kind, caution: caution))
                    .font(.appCaption)
                    .foregroundColor(.appTextSecondary)
                    .lineLimit(2)
            }
        }
        .tint(.appAccentMuted)
        .accessibilityIdentifier("favorites-offline-scope-\(kind.rawValue)")
    }

    private func previewDetail(for kind: FavoritesOfflineScopePreview.Kind, caution: String?) -> String {
        guard let preview = sync.previews.first(where: { $0.kind == kind }) else {
            return caution ?? "Counting…"
        }
        guard preview.itemCount > 0 else {
            return "Nothing liked yet"
        }

        let size = downloadManager.formatBytes(sync.estimatedBytes(forDuration: preview.duration))
        let items: String
        switch kind {
        case .tracks:
            items = "\(preview.itemCount) \(preview.itemCount == 1 ? "track" : "tracks")"
        case .albums:
            items = "\(preview.itemCount) \(preview.itemCount == 1 ? "album" : "albums") · \(preview.trackCount) tracks"
        case .artists:
            items = "\(preview.itemCount) \(preview.itemCount == 1 ? "artist" : "artists") · \(preview.trackCount) tracks"
        }

        let base = "\(items) · ~\(size)"
        guard let caution else { return base }
        return "\(base). \(caution)"
    }

    // MARK: - Network

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Network")
                .font(.appHeadline)
                .foregroundColor(.appAccent)

            Toggle(isOn: $sync.allowsCellular) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Download over Cellular")
                        .font(.appBody)
                        .foregroundColor(.appText)
                    Text("Off means downloads wait for Wi-Fi. Albums you download by hand always start right away.")
                        .font(.appCaption)
                        .foregroundColor(.appTextSecondary)
                }
            }
            .tint(.appAccentMuted)
            .settingsCard()
            .accessibilityIdentifier("favorites-offline-cellular")
        }
    }

    // MARK: - Stop

    private var stopSection: some View {
        Button {
            showStopDialog = true
        } label: {
            HStack {
                Image(systemName: "xmark.circle")
                Text("Turn Off")
                    .font(.appHeadline)
                Spacer()
            }
            .foregroundColor(.appWarning)
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.appWarning.opacity(0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.appWarning.opacity(0.5), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("favorites-offline-turn-off")
    }

    // MARK: - Status derivation

    private var failureCount: Int {
        guard case .failed(_, _, let failures) = sync.status else { return 0 }
        return failures
    }

    private var isWorking: Bool {
        switch sync.status {
        case .syncing, .paused, .waitingForWiFi: return true
        default: return false
        }
    }

    private var statusProgress: Double? {
        switch sync.status {
        case .syncing(let completed, let total), .paused(let completed, let total):
            guard total > 0 else { return nil }
            return Double(completed) / Double(total)
        default:
            return nil
        }
    }

    private var statusIcon: String {
        switch sync.status {
        case .off: return "heart.slash"
        case .unavailable: return "exclamationmark.triangle"
        case .upToDate: return "checkmark.circle"
        case .syncing: return "arrow.down.circle"
        case .waitingForWiFi: return "wifi.exclamationmark"
        case .paused: return "pause.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var statusColor: Color {
        switch sync.status {
        case .off: return .appTextSecondary
        case .unavailable, .failed: return .appWarning
        case .upToDate: return .appSuccess
        case .syncing, .waitingForWiFi, .paused: return .appAccent
        }
    }

    private var statusTitle: String {
        switch sync.status {
        case .off: return "Off"
        case .unavailable: return "Library unavailable"
        case .upToDate(let count): return count == 0 ? "Nothing to download" : "Up to date"
        case .syncing: return "Downloading"
        case .waitingForWiFi: return "Waiting for Wi-Fi"
        case .paused: return "Paused"
        case .failed: return "Finished with errors"
        }
    }

    private var statusDetail: String {
        switch sync.status {
        case .off:
            return "Your liked tracks and albums are downloaded and kept up to date."
        case .unavailable:
            return "Sign in and sync your library to use this."
        case .upToDate(let count):
            guard count > 0 else { return "Like some music and it will appear here." }
            return "\(count) \(count == 1 ? "track" : "tracks") available offline"
        case .syncing(let completed, let total):
            return "\(completed) of \(total) downloaded"
        case .waitingForWiFi(let remaining):
            return "\(remaining) \(remaining == 1 ? "track" : "tracks") remaining. Turn on cellular downloads to continue now."
        case .paused(let completed, let total):
            return "\(completed) of \(total) downloaded"
        case .failed(let completed, _, let failures):
            return "\(completed) downloaded · \(failures) failed"
        }
    }
}

// MARK: - Start Sheet

/// Shown before the first byte is downloaded. A rule that can commit several
/// gigabytes should never begin on a switch flip alone.
private struct FavoritesOfflineStartSheet: View {
    @ObservedObject private var sync = FavoritesOfflineSync.shared
    @ObservedObject private var downloadManager = DownloadManager.shared
    @Environment(\.dismiss) private var dismiss

    let onConfirm: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Aurelia will download everything you have liked and keep it up to date as you like and unlike music.")
                        .font(.appBody)
                        .foregroundColor(.appTextSecondary)

                    scopeCard
                    estimateCard
                    cellularCard

                    Color.clear.frame(height: 60)
                }
                .padding()
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Keep Favorites Offline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Download") {
                        onConfirm()
                        dismiss()
                    }
                    .disabled(sync.scope.isEmpty || totalMissingTracks == 0)
                    .accessibilityIdentifier("favorites-offline-confirm")
                }
            }
            .task {
                await sync.loadPreviews()
            }
        }
    }

    private var scopeCard: some View {
        VStack(spacing: 14) {
            row(title: "Liked Tracks", kind: .tracks, isOn: $sync.scope.includesTracks)
            Divider().background(Color.appControlFill)
            row(title: "Liked Albums", kind: .albums, isOn: $sync.scope.includesAlbums)
            Divider().background(Color.appControlFill)
            row(title: "Liked Artists", kind: .artists, isOn: $sync.scope.includesArtists)
        }
        .settingsCard()
    }

    private func row(
        title: String,
        kind: FavoritesOfflineScopePreview.Kind,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            HStack {
                Text(title)
                    .font(.appBody)
                    .foregroundColor(.appText)
                Spacer()
                if let preview = sync.previews.first(where: { $0.kind == kind }) {
                    Text("\(preview.trackCount) · ~\(downloadManager.formatBytes(sync.estimatedBytes(forDuration: preview.duration)))")
                        .font(.appMono)
                        .foregroundColor(.appTextSecondary)
                }
            }
        }
        .tint(.appAccentMuted)
    }

    private var estimateCard: some View {
        HStack(spacing: 14) {
            Image(systemName: fits ? "internaldrive" : "exclamationmark.triangle")
                .font(.title2)
                .foregroundColor(fits ? .appAccent : .appWarning)

            VStack(alignment: .leading, spacing: 4) {
                Text("~\(downloadManager.formatBytes(estimatedBytes))")
                    .font(.title3.weight(.bold))
                    .foregroundColor(.appText)
                Text(fits
                     ? "\(totalMissingTracks) tracks to download · \(downloadManager.formatBytes(freeBytes)) free"
                     : "Not enough space · \(downloadManager.formatBytes(freeBytes)) free")
                    .font(.appCaption)
                    .foregroundColor(fits ? .appTextSecondary : .appWarning)
            }

            Spacer()
        }
        .settingsCard()
        .accessibilityIdentifier("favorites-offline-estimate")
    }

    private var cellularCard: some View {
        Toggle(isOn: $sync.allowsCellular) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Download over Cellular")
                    .font(.appBody)
                    .foregroundColor(.appText)
                Text("Off means this waits for Wi-Fi.")
                    .font(.appCaption)
                    .foregroundColor(.appTextSecondary)
            }
        }
        .tint(.appAccentMuted)
        .settingsCard()
    }

    /// The sheet estimates from the selected scopes directly. Tracks counted
    /// twice — liked, and on a liked album — are one file, but the previews are
    /// computed per scope, so this is an upper bound and is labelled with a "~".
    private var selectedPreviews: [FavoritesOfflineScopePreview] {
        sync.previews.filter { preview in
            switch preview.kind {
            case .tracks: return sync.scope.includesTracks
            case .albums: return sync.scope.includesAlbums
            case .artists: return sync.scope.includesArtists
            }
        }
    }

    private var totalMissingTracks: Int {
        selectedPreviews.reduce(0) { $0 + $1.trackCount }
    }

    private var estimatedBytes: Int64 {
        sync.estimatedBytes(forDuration: selectedPreviews.reduce(0) { $0 + $1.duration })
    }

    private var freeBytes: Int64 {
        FavoritesOfflineSync.freeDiskBytes()
    }

    private var fits: Bool {
        estimatedBytes < Int64(Double(freeBytes) * 0.9)
    }
}

#Preview {
    NavigationStack {
        FavoritesOfflineView()
    }
}
