import Foundation

/// Foreground-only Jellyfin WebSocket listener. Events are deliberately
/// treated as invalidation hints: the timestamp delta remains authoritative,
/// which also covers events missed while the app was suspended.
@MainActor
final class JellyfinLibraryEventStream {
    enum Event {
        case libraryChanged
        case userDataChanged
        case reconnected
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

    init(service: JellyfinService) {
        self.service = service
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

    private func connect() {
        guard shouldRun, service.isAuthenticated,
              let request = try? service.makeLibraryWebSocketRequest(
                path: routes[routeIndex]
              ) else {
            stop()
            return
        }
        let task = URLSession.shared.webSocketTask(with: request)
        socket = task
        task.resume()
        receiveTask = Task { @MainActor [weak self] in
            await self?.receiveLoop(task, isReconnect: self?.connectedOnce == true)
        }
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
                case "LibraryChanged": onEvent?(.libraryChanged)
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
            if !receivedMessage { routeIndex = 0 }
            reconnectAttempt += 1
            let delay = min(pow(2, Double(reconnectAttempt - 1)), 60)
            try? await Task.sleep(for: .seconds(delay))
            guard shouldRun else { return }
            connect()
        }
    }

    private struct Envelope: Decodable {
        let MessageType: String
    }
}
