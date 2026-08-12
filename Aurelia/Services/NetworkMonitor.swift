//
//  NetworkMonitor.swift
//  Aurelia
//
//  Tracks whether the Jellyfin server can be reached right now.
//

import Combine
import Foundation
import Network

/// Driven by events rather than by polling. Two of them arrive on their own:
/// the system reports interface changes, and the Jellyfin WebSocket reports
/// when it opens or drops. Ordinary API traffic contributes a third, since a
/// request that just succeeded or just failed on connectivity knows more than
/// any probe would.
///
/// A probe survives in one place only — confirming a dropped socket — because
/// a WebSocket can fail on its own, behind a proxy that will not pass upgrades
/// say, while plain HTTP to the same server is perfectly fine. Marking the
/// library unavailable on that alone would be a lie the user cannot argue with.
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    /// True when anything that has to stream will fail. Starts optimistic so a
    /// cold launch never flashes the whole library as unavailable.
    @Published private(set) var isOffline = false

    /// Called when an interface comes back, so a listener sitting in a
    /// reconnect backoff can retry immediately instead of waiting it out.
    var onPathRestored: (() -> Void)?

    private let pathMonitor: NWPathMonitor?
    private let probe: () async -> Bool
    private let pathQueue = DispatchQueue(label: "de.beutner.Aurelia.network-path")
    private var hasPath = true
    private var serverReachable = true
    private var probeTask: Task<Void, Never>?
    private var isStarted = false

    init(
        pathMonitor: NWPathMonitor? = NWPathMonitor(),
        probe: @escaping () async -> Bool = {
            let service = JellyfinService.shared
            // An unconfigured server is not the same thing as an unreachable
            // one; onboarding should not look like an outage.
            guard !service.baseURL.isEmpty else { return true }
            return (try? await service.checkServerConnectivity()) ?? false
        }
    ) {
        self.pathMonitor = pathMonitor
        self.probe = probe
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        pathMonitor?.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                self?.pathDidChange(satisfied: satisfied)
            }
        }
        pathMonitor?.start(queue: pathQueue)
    }

    /// A request that just reached the server settles the question outright.
    func noteServerReachable() {
        probeTask?.cancel()
        serverReachable = true
        recompute()
    }

    /// For callers holding firsthand evidence — an HTTP request that failed on
    /// connectivity. No confirmation needed, the request *was* the test.
    func noteServerUnreachable() {
        probeTask?.cancel()
        serverReachable = false
        recompute()
    }

    /// For the secondhand case: a listener lost its connection, which may or
    /// may not mean the server is gone. Confirmed with one request before
    /// anything gets marked up.
    func noteServerConnectionLost() {
        guard hasPath else {
            serverReachable = false
            recompute()
            return
        }
        refresh()
    }

    /// Re-confirms reachability. Event-triggered, never on a timer — the app
    /// calls this on the way back to the foreground, where events that fired
    /// while it was suspended were never delivered.
    func refresh() {
        probeTask?.cancel()
        probeTask = Task { [weak self] in
            await self?.probeServer()
        }
    }

    /// Runs a single probe to completion. Split out from `refresh` so a caller
    /// that needs the answer — a test, mainly — can await one.
    func probeServer() async {
        guard hasPath else {
            // Without an interface the probe can only sit there and time out.
            serverReachable = false
            recompute()
            return
        }
        let reachable = await probe()
        guard !Task.isCancelled else { return }
        serverReachable = reachable
        recompute()
    }

    private func pathDidChange(satisfied: Bool) {
        guard satisfied != hasPath else { return }
        hasPath = satisfied
        if satisfied {
            onPathRestored?()
            // The socket will report back shortly, but a probe covers the case
            // where it is blocked and cannot report anything at all.
            refresh()
        } else {
            probeTask?.cancel()
            serverReachable = false
            recompute()
        }
    }

    private func recompute() {
        let offline = !hasPath || !serverReachable
        guard offline != isOffline else { return }
        isOffline = offline
    }
}
