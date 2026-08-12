//
//  WatchConnectivityManager.swift
//  Aurelia Watch
//
//  Syncs authentication and favorites between iPhone and Apple Watch
//

import Foundation
import WatchConnectivity
import Combine

/// Manages WatchConnectivity session for watch app - syncs credentials and favorites
class WatchConnectivityManager: NSObject, ObservableObject {
    static let shared = WatchConnectivityManager()

    @Published var isPhoneReachable = false

    private var session: WCSession?
    private let jellyfinService = WatchJellyfinService.shared
    private var lastLibraryRequestAt: Date?
    private var incomingSnapshots: [String: IncomingSnapshot] = [:]

    private struct IncomingSnapshot {
        let chunkCount: Int
        var chunks: [Int: Data] = [:]
    }

    override init() {
        super.init()

        if WCSession.isSupported() {
            session = WCSession.default
            session?.delegate = self
            session?.activate()
        }
    }

    // MARK: - Request Credentials

    func requestCredentials() {
        guard let session = session, session.isReachable else {
            print("⚠️ Phone not reachable - cannot sync credentials")
            return
        }

        let message: [String: Any] = ["action": "requestCredentials"]
        session.sendMessage(message, replyHandler: { reply in
            self.handleCredentialsReply(reply)
        }) { error in
            print("❌ Failed to request credentials: \(error.localizedDescription)")
        }
    }

    func requestLibrarySnapshot() {
        guard let session, session.activationState == .activated, session.isReachable else {
            print("⚠️ Phone not reachable - Watch will use its cached library or direct fallback")
            return
        }
        if let lastLibraryRequestAt,
           Date().timeIntervalSince(lastLibraryRequestAt) < 5 {
            return
        }
        lastLibraryRequestAt = Date()

        session.sendMessage(
            ["action": "requestLibrarySnapshot"],
            replyHandler: { _ in },
            errorHandler: { error in
                print("❌ Failed to request library snapshot: \(error.localizedDescription)")
            }
        )
    }

    private func handleCredentialsReply(_ reply: [String: Any]) {
        guard let baseURL = reply["baseURL"] as? String,
              let accessToken = reply["accessToken"] as? String,
              let userId = reply["userId"] as? String,
              let userName = reply["userName"] as? String else {
            print("⚠️ Invalid credentials response")
            return
        }

        DispatchQueue.main.async {
            self.jellyfinService.setCredentials(
                baseURL: baseURL,
                accessToken: accessToken,
                userId: userId,
                userName: userName
            )
            print("✅ Synced credentials from iPhone")
        }
    }
}

// MARK: - WCSessionDelegate

extension WatchConnectivityManager: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error = error {
            print("❌ Watch session activation failed: \(error.localizedDescription)")
        } else {
            print("✅ Watch session activated")
            DispatchQueue.main.async {
                self.isPhoneReachable = session.isReachable
                self.syncFromContext(session.receivedApplicationContext)
                self.requestCredentials()
                self.requestLibrarySnapshot()
            }
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isPhoneReachable = session.isReachable
            print("📱 Phone reachable: \(session.isReachable)")
            if session.isReachable {
                self.requestCredentials()
                self.requestLibrarySnapshot()
            }
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        DispatchQueue.main.async {
            self.syncFromContext(applicationContext)
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        if message["action"] as? String == "librarySnapshotChunk" {
            guard let transferID = message["transferID"] as? String,
                  let chunkIndex = message["chunkIndex"] as? Int,
                  let chunkCount = message["chunkCount"] as? Int,
                  let data = message["data"] as? Data,
                  chunkCount > 0,
                  chunkIndex >= 0,
                  chunkIndex < chunkCount else {
                replyHandler(["accepted": false])
                return
            }

            DispatchQueue.main.async {
                self.receiveLibrarySnapshotChunk(
                    data,
                    transferID: transferID,
                    chunkIndex: chunkIndex,
                    chunkCount: chunkCount
                )
            }
            replyHandler(["accepted": true])
            return
        }

        if let action = message["action"] as? String, action == "requestCredentials" {
            // This shouldn't happen on watch, but handle gracefully
            replyHandler([:])
            return
        }

        DispatchQueue.main.async {
            self.syncFromContext(message)
        }
    }

    private func receiveLibrarySnapshotChunk(
        _ data: Data,
        transferID: String,
        chunkIndex: Int,
        chunkCount: Int
    ) {
        var incoming = incomingSnapshots[transferID]
            ?? IncomingSnapshot(chunkCount: chunkCount)
        guard incoming.chunkCount == chunkCount else {
            incomingSnapshots.removeValue(forKey: transferID)
            return
        }
        incoming.chunks[chunkIndex] = data
        incomingSnapshots[transferID] = incoming

        guard incoming.chunks.count == chunkCount else { return }
        var snapshotData = Data()
        snapshotData.reserveCapacity(incoming.chunks.values.reduce(0) { $0 + $1.count })
        for index in 0..<chunkCount {
            guard let chunk = incoming.chunks[index] else { return }
            snapshotData.append(chunk)
        }
        incomingSnapshots.removeValue(forKey: transferID)

        Task { @MainActor in
            await WatchLibraryStore.shared.applyTransferredSnapshot(snapshotData)
        }
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard file.metadata?["type"] as? String == "librarySnapshot" else { return }
        do {
            let data = try Data(contentsOf: file.fileURL)
            Task { @MainActor in
                await WatchLibraryStore.shared.applyTransferredSnapshot(data)
            }
        } catch {
            print("❌ Failed to read transferred library snapshot: \(error.localizedDescription)")
        }
    }

    private func syncFromContext(_ context: [String: Any]) {
        // Sync credentials if provided
        if let baseURL = context["baseURL"] as? String,
           let accessToken = context["accessToken"] as? String,
           let userId = context["userId"] as? String,
           let userName = context["userName"] as? String {
            jellyfinService.setCredentials(
                baseURL: baseURL,
                accessToken: accessToken,
                userId: userId,
                userName: userName
            )
            print("✅ Auto-synced credentials from iPhone")
            requestLibrarySnapshot()
        }

        // TODO: Sync favorites, play history, etc.
    }
}
