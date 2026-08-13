import Foundation

/// Foreground-only Jellyfin WebSocket listener. Events are deliberately
/// treated as invalidation hints: the timestamp delta remains authoritative,
/// which also covers events missed while the app was suspended.
@MainActor
final class JellyfinLibraryEventStream {
    enum Event {
        case libraryChanged
        /// Items the server says are gone. Carried in the same message as the
        /// change notice, so deletions need not wait for a reconciliation.
        case itemsRemoved([String])
        case userDataChanged
        case reconnected
        /// The handshake completed — firsthand proof the server is answering.
        case connected
        /// The socket dropped on its own. Deliberate teardown stays silent.
        case disconnected
    }

    private let service: JellyfinService
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var shouldRun = false
    private var connectedOnce = false
    private var reconnectAttempt = 0
    private var routeIndex = 0
    private var onEvent: ((Event) -> Void)?
    private let routes = ["socket", "embywebsocket"]
    private var socketSession: URLSession?

    init(service: JellyfinService) {
        self.service = service
    }

    deinit {
        socketSession?.invalidateAndCancel()
    }

    func start(onEvent: @escaping (Event) -> Void) {
        self.onEvent = onEvent
        guard !shouldRun else { return }
        shouldRun = true
        connect()
    }

    func stop() {
        shouldRun = false
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    /// Collapses the reconnect backoff when something outside says the network
    /// is back, so recovery is not left waiting out a delay that was scheduled
    /// before the fix landed.
    func reconnectNow() {
        guard shouldRun else { return }
        reconnectAttempt = 0
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        connect()
    }

    private func connect() {
        guard shouldRun, service.isAuthenticated,
              let request = try? service.makeLibraryWebSocketRequest(
                path: routes[routeIndex]
              ) else {
            stop()
            return
        }
        let task = session().webSocketTask(with: request)
        socket = task
        task.resume()
        receiveTask = Task { @MainActor [weak self] in
            await self?.receiveLoop(task, isReconnect: self?.connectedOnce == true)
        }
    }

    /// The handshake is only reported through a delegate, so the socket needs a
    /// session of its own rather than the shared one.
    private func session() -> URLSession {
        if let socketSession { return socketSession }
        let observer = SocketOpenObserver { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.shouldRun else { return }
                self.onEvent?(.connected)
            }
        }
        let session = URLSession(configuration: .default, delegate: observer, delegateQueue: nil)
        socketSession = session
        return session
    }

    private func receiveLoop(
        _ task: URLSessionWebSocketTask,
        isReconnect: Bool
    ) async {
        var receivedMessage = false
        do {
            while shouldRun, !Task.isCancelled {
                let message = try await task.receive()
                if !receivedMessage {
                    receivedMessage = true
                    reconnectAttempt = 0
                    connectedOnce = true
                    if isReconnect { onEvent?(.reconnected) }
                }
                let data: Data?
                switch message {
                case .data(let value): data = value
                case .string(let value): data = value.data(using: .utf8)
                @unknown default: data = nil
                }
                guard let data,
                      let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
                    continue
                }
                switch envelope.MessageType {
                case "LibraryChanged":
                    let removed = envelope.Data?.ItemsRemoved ?? []
                    if !removed.isEmpty { onEvent?(.itemsRemoved(removed)) }
                    onEvent?(.libraryChanged)
                case "UserDataChanged": onEvent?(.userDataChanged)
                case "ForceKeepAlive":
                    try await task.send(.string("{\"MessageType\":\"KeepAlive\"}"))
                case "KeepAlive": break
                default: break
                }
            }
        } catch {
            guard shouldRun, !Task.isCancelled else { return }
            socket = nil
            // Jellyfin normally exposes `/socket`, while some older or
            // compatibility-oriented proxies expose `/embywebsocket`.
            // Probe the fallback once before applying reconnect backoff.
            if !receivedMessage, routeIndex + 1 < routes.count {
                routeIndex += 1
                connect()
                return
            }
            onEvent?(.disconnected)
            if !receivedMessage { routeIndex = 0 }
            reconnectAttempt += 1
            let delay = min(pow(2, Double(reconnectAttempt - 1)), 60)
            try? await Task.sleep(for: .seconds(delay))
            // `reconnectNow` cancels this task to skip the rest of the backoff
            // and has already started a fresh connection of its own.
            guard shouldRun, !Task.isCancelled else { return }
            connect()
        }
    }

    private struct Envelope: Decodable {
        let MessageType: String
        let Data: LibraryUpdateInfo?

        /// Only the part that cannot be recovered from a later query. Additions
        /// and updates are found by the watermark sweep; a deletion leaves
        /// nothing behind to find.
        struct LibraryUpdateInfo: Decodable {
            let ItemsRemoved: [String]?
        }
    }
}

/// URLSession reports a completed WebSocket handshake only to a delegate, and
/// that moment is the earliest honest proof that the server is up — waiting for
/// the server's first message would conflate "unreachable" with "quiet".
private final class SocketOpenObserver: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let onOpen: @Sendable () -> Void

    init(onOpen: @escaping @Sendable () -> Void) {
        self.onOpen = onOpen
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        onOpen()
    }
}
