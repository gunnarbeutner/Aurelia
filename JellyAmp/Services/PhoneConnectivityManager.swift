//
//  PhoneConnectivityManager.swift
//  JellyAmp
//
//  Manages communication with Apple Watch
//  Sends playback state updates and handles remote control commands from watch
//

import Foundation
import WatchConnectivity
import Combine

/// Manages WatchConnectivity session for iPhone app
class PhoneConnectivityManager: NSObject, ObservableObject {
    static let shared = PhoneConnectivityManager()

    private var session: WCSession?
    private var cancellables = Set<AnyCancellable>()
    private let playerManager = PlayerManager.shared
    private var pendingSnapshotFiles = Set<URL>()
    private var lastQueuedSnapshotDates: [String: Date] = [:]

    override init() {
        super.init()

        if WCSession.isSupported() {
            session = WCSession.default
            session?.delegate = self
            session?.activate()
        }

        // Observe player state changes and send to watch
        setupPlayerObservers()
    }

    // MARK: - Setup Observers

    private func setupPlayerObservers() {
        // Observe authentication changes and sync to watch
        JellyfinService.shared.$isAuthenticated
            .sink { [weak self] isAuth in
                if isAuth {
                    self?.syncCredentialsToWatch()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Sync Credentials to Watch

    func syncCredentialsToWatch() {
        guard let session = session, session.activationState == .activated else {
            return
        }

        let jellyfin = JellyfinService.shared

        guard jellyfin.isAuthenticated,
              let accessToken = KeychainService.shared.getAccessToken(),
              let userId = UserDefaults.standard.string(forKey: "jellyfinUserId") else {
            print("⚠️ Cannot sync - not authenticated")
            return
        }

        let context: [String: Any] = [
            "baseURL": jellyfin.baseURL,
            "accessToken": accessToken,
            "userId": userId,
            "userName": jellyfin.currentUser?.Name ?? "User"
        ]

        // Send as application context (persistent)
        do {
            try session.updateApplicationContext(context)
            print("✅ Synced credentials to watch")
        } catch {
            print("❌ Failed to sync credentials: \(error)")
        }
    }

    /// Transfers a credential-free, versioned copy of the complete SQLite
    /// catalog. WatchConnectivity owns delivery, so this also works while the
    /// Watch app is suspended or temporarily unreachable.
    func syncLibrarySnapshotToWatch(
        snapshot: LibrarySnapshot,
        scope: LibraryScope,
        force: Bool = false
    ) {
        guard snapshot.hasCachedLibrary,
              let session,
              session.activationState == .activated,
              session.isWatchAppInstalled else {
            return
        }

        let generatedAt = snapshot.lastSyncedAt ?? Date()
        let transferKey = "\(scope.serverKey)\u{0}\(scope.userID)"
        guard force || lastQueuedSnapshotDates[transferKey] != generatedAt else { return }

        let payload = PhoneWatchLibrarySnapshot(
            scope: .init(serverKey: scope.serverKey, userID: scope.userID),
            generatedAt: generatedAt,
            artists: snapshot.artists.map {
                .init(id: $0.id, name: $0.name)
            },
            albums: snapshot.albums.map {
                .init(
                    id: $0.id,
                    name: $0.name,
                    artist: $0.artistName,
                    artistId: $0.artistId,
                    year: $0.year
                )
            },
            tracks: snapshot.tracks.map {
                .init(
                    id: $0.id,
                    name: $0.name,
                    artist: $0.artistName,
                    artistIds: $0.artistIDs ?? $0.artistId.map { [$0] } ?? [],
                    album: $0.albumName,
                    albumId: $0.albumId ?? "",
                    duration: $0.duration,
                    indexNumber: $0.indexNumber,
                    parentIndexNumber: $0.parentIndexNumber,
                    isFavorite: $0.isFavorite
                )
            }
        )

        do {
            let data = try JSONEncoder().encode(payload)
            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("JellyAmp-Watch-Library-\(UUID().uuidString)")
                .appendingPathExtension("json")
            try data.write(to: fileURL, options: .atomic)
            pendingSnapshotFiles.insert(fileURL)
            lastQueuedSnapshotDates[transferKey] = generatedAt
            session.transferFile(
                fileURL,
                metadata: [
                    "type": "librarySnapshot",
                    "version": PhoneWatchLibrarySnapshot.currentVersion
                ]
            )
            print("✅ Queued SQLite library snapshot for watch")
        } catch {
            print("❌ Failed to prepare watch library snapshot: \(error.localizedDescription)")
        }
    }

    func syncCurrentLibrarySnapshotToWatch(force: Bool = false) async {
        guard let scope = JellyfinService.shared.libraryScope,
              let snapshot = try? await LibraryRepository.shared.librarySnapshot(in: scope) else {
            return
        }
        syncLibrarySnapshotToWatch(snapshot: snapshot, scope: scope, force: force)
    }
}

// MARK: - WCSessionDelegate

extension PhoneConnectivityManager: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error = error {
            print("❌ Phone session activation failed: \(error.localizedDescription)")
        } else {
            print("✅ Phone session activated")
            // Sync credentials to watch
            syncCredentialsToWatch()
            Task { @MainActor [weak self] in
                await self?.syncCurrentLibrarySnapshotToWatch(force: true)
            }
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        print("📱 Session became inactive")
    }

    func sessionDidDeactivate(_ session: WCSession) {
        print("📱 Session deactivated")
        // Reactivate for new watch
        session.activate()
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        print("📱 Watch reachable: \(session.isReachable)")
        if session.isReachable {
            syncCredentialsToWatch()
            Task { @MainActor [weak self] in
                await self?.syncCurrentLibrarySnapshotToWatch(force: true)
            }
        }
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        syncCredentialsToWatch()
        Task { @MainActor [weak self] in
            await self?.syncCurrentLibrarySnapshotToWatch(force: true)
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        if let action = message["action"] as? String, action == "requestCredentials" {
            // Watch is requesting credentials
            handleCredentialsRequest(replyHandler: replyHandler)
            return
        }

        if let action = message["action"] as? String, action == "requestLibrarySnapshot" {
            replyHandler(["accepted": true])
            Task { @MainActor [weak self] in
                await self?.syncCurrentLibrarySnapshotToWatch(force: true)
            }
            return
        }

        replyHandler([:])
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let fileURL = fileTransfer.file.fileURL
        Task { @MainActor [weak self] in
            self?.pendingSnapshotFiles.remove(fileURL)
            try? FileManager.default.removeItem(at: fileURL)
            if let error {
                print("❌ Watch library snapshot transfer failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Handle Credentials Request

    private func handleCredentialsRequest(replyHandler: @escaping ([String: Any]) -> Void) {
        let jellyfin = JellyfinService.shared

        guard jellyfin.isAuthenticated,
              let accessToken = KeychainService.shared.getAccessToken(),
              let userId = UserDefaults.standard.string(forKey: "jellyfinUserId") else {
            print("⚠️ Cannot provide credentials - not authenticated")
            replyHandler([:])
            return
        }

        let credentials: [String: Any] = [
            "baseURL": jellyfin.baseURL,
            "accessToken": accessToken,
            "userId": userId,
            "userName": jellyfin.currentUser?.Name ?? "User"
        ]

        print("✅ Sending credentials to watch")
        replyHandler(credentials)
    }
}

private nonisolated struct PhoneWatchLibrarySnapshot: Codable, Sendable {
    static let currentVersion = 1

    let version: Int
    let scope: PhoneWatchLibraryScope
    let generatedAt: Date
    let artists: [PhoneWatchArtist]
    let albums: [PhoneWatchAlbum]
    let tracks: [PhoneWatchTrack]

    init(
        scope: PhoneWatchLibraryScope,
        generatedAt: Date,
        artists: [PhoneWatchArtist],
        albums: [PhoneWatchAlbum],
        tracks: [PhoneWatchTrack]
    ) {
        version = Self.currentVersion
        self.scope = scope
        self.generatedAt = generatedAt
        self.artists = artists
        self.albums = albums
        self.tracks = tracks
    }
}

private nonisolated struct PhoneWatchLibraryScope: Codable, Sendable {
    let serverKey: String
    let userID: String
}

private nonisolated struct PhoneWatchArtist: Codable, Sendable {
    let id: String
    let name: String
}

private nonisolated struct PhoneWatchAlbum: Codable, Sendable {
    let id: String
    let name: String
    let artist: String
    let artistId: String?
    let year: Int?
}

private nonisolated struct PhoneWatchTrack: Codable, Sendable {
    let id: String
    let name: String
    let artist: String
    let artistIds: [String]
    let album: String
    let albumId: String
    let duration: TimeInterval
    let indexNumber: Int?
    let parentIndexNumber: Int?
    let isFavorite: Bool
}
