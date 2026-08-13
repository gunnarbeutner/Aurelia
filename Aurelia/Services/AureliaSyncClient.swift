import Foundation

@MainActor
final class AureliaSyncClient {
    static let shared = AureliaSyncClient(service: .shared)

    static let protocolRange = 1...1
    static let schemaRange = 1...1
    static let pluginGUID = "3fbf911d-ab0c-46dc-81d6-b3317bb8b176"
    static let repositoryURL = "https://gunnarbeutner.github.io/AureliaSync/manifest.json"

    private let service: JellyfinService
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder.aureliaSync

    init(service: JellyfinService, session: URLSession = .shared) {
        self.service = service
        self.session = session
    }

    func status() async throws -> AureliaSyncStatus {
        let request = try service.makeAuthenticatedRequest(path: "AureliaSync/v1/status")
        return try await value(for: request)
    }

    func openSession(checkpoint: String?, reset: Bool = false) async throws -> AureliaSyncSession {
        let body = AureliaSyncOpenSessionRequest(
            clientId: try KeychainService.shared.aureliaSyncClientID(),
            clientVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1",
            protocolMin: Self.protocolRange.lowerBound,
            protocolMax: Self.protocolRange.upperBound,
            schemaMin: Self.schemaRange.lowerBound,
            schemaMax: Self.schemaRange.upperBound,
            checkpointToken: checkpoint,
            reset: reset
        )
        var request = try service.makeAuthenticatedRequest(path: "AureliaSync/v1/sessions")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        return try await value(for: request)
    }

    func stream(session syncSession: AureliaSyncSession, after cursor: String?) async throws -> AureliaSyncDecodedSegment {
        var path = "AureliaSync/v1/sessions/\(syncSession.sessionId)/stream?maxRecords=1000&maxBytes=8388608"
        if let cursor {
            path += "&after=" + (cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cursor)
        }
        var request = try service.makeAuthenticatedRequest(path: path)
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Accept")
        let networkSession = session

        // This decoder performs substantial per-byte work: it splits NDJSON,
        // decodes up to 1,000 records, and hashes their exact payload bytes.
        // AureliaSyncClient is main-actor isolated because it builds requests
        // from the signed-in service. Letting that work inherit the caller's
        // executor stalls every SwiftUI animation while a segment arrives,
        // which is especially visible on physical devices.
        return try await Task.detached(priority: .utility) {
            let (bytes, response) = try await networkSession.bytes(for: request)
            try Self.validateStreamResponse(response)
            return try await AureliaSyncNDJSON.decode(bytes: bytes)
        }.value
    }

    func acknowledge(_ acknowledgement: AureliaSyncAcknowledgement, sessionID: String) async throws -> String? {
        var request = try service.makeAuthenticatedRequest(path: "AureliaSync/v1/sessions/\(sessionID)/ack")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(acknowledgement)
        let (data, response) = try await session.data(for: request)
        try validate(response: response, body: data)
        struct AckResponse: Decodable { let checkpointToken: String? }
        return (try? decoder.decode(AckResponse.self, from: data))?.checkpointToken
    }

    func close(sessionID: String) async {
        guard var request = try? service.makeAuthenticatedRequest(path: "AureliaSync/v1/sessions/\(sessionID)") else { return }
        request.httpMethod = "DELETE"
        _ = try? await session.data(for: request)
    }

    private func value<T: Decodable>(for request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        try validate(response: response, body: data)
        return try decoder.decode(T.self, from: data)
    }

    private func validate(response: URLResponse, body: Data?) throws {
        guard let http = response as? HTTPURLResponse else { throw AureliaSyncError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let detail = body.flatMap { data -> (String, String, String?)? in
                struct Failure: Decodable {
                    struct Detail: Decodable { let code: String?; let message: String?; let correlationId: String? }
                    let code: String?
                    let message: String?
                    let correlationId: String?
                    let error: Detail?
                }
                guard let envelope = try? decoder.decode(Failure.self, from: data) else { return nil }
                let failure = envelope.error ?? .init(
                    code: envelope.code,
                    message: envelope.message,
                    correlationId: envelope.correlationId
                )
                return (failure.code ?? "http\(http.statusCode)", failure.message ?? "Aurelia Sync request failed.", failure.correlationId)
            }
            if http.statusCode == 404 { throw AureliaSyncError.required }
            if http.statusCode == 429 {
                throw AureliaSyncError.rateLimited(
                    retryAfter: Self.retryAfter(from: http),
                    message: detail?.1
                )
            }
            if let detail { throw AureliaSyncError.structured(code: detail.0, message: detail.1, correlationId: detail.2) }
            throw AureliaSyncError.http(http.statusCode, body.flatMap { String(data: $0, encoding: .utf8) })
        }
    }

    nonisolated private static func validateStreamResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AureliaSyncError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 404 { throw AureliaSyncError.required }
            if http.statusCode == 429 {
                throw AureliaSyncError.rateLimited(retryAfter: retryAfter(from: http), message: nil)
            }
            throw AureliaSyncError.http(http.statusCode, nil)
        }
    }

    nonisolated private static func retryAfter(from response: HTTPURLResponse) -> Date? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return Date().addingTimeInterval(max(0, seconds))
        }
        return HTTPDateParser.date(from: value)
    }
}

nonisolated private enum HTTPDateParser {
    static func date(from value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: value)
    }
}

nonisolated struct JellyfinPluginRepository: Codable, Equatable, Sendable {
    let Name: String
    let Url: String
    let Enabled: Bool
}

nonisolated struct JellyfinUserPolicy: Decodable, Sendable {
    let IsAdministrator: Bool
}

/// Standard Jellyfin administrative APIs used only to install/update the
/// required sync plugin. They are deliberately separate from sync transport.
@MainActor
final class AureliaSyncPluginManager {
    static let shared = AureliaSyncPluginManager(service: .shared)
    private let service: JellyfinService
    private let session = URLSession.shared
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(service: JellyfinService) { self.service = service }

    func currentUserIsAdministrator() async throws -> Bool {
        var request = try service.makeAuthenticatedRequest(path: "Users/Me")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return false }
        struct User: Decodable { let Policy: JellyfinUserPolicy? }
        return try decoder.decode(User.self, from: data).Policy?.IsAdministrator == true
    }

    func install() async throws {
        let repositories: [JellyfinPluginRepository] = try await get(path: "Repositories")
        var preserved = repositories
        if !preserved.contains(where: { $0.Url.caseInsensitiveCompare(AureliaSyncClient.repositoryURL) == .orderedSame }) {
            preserved.append(.init(Name: "Aurelia Sync", Url: AureliaSyncClient.repositoryURL, Enabled: true))
            try await send(path: "Repositories", method: "POST", body: preserved)
        }
        let encodedName = "Aurelia%20Sync"
        try await send(
            path: "Packages/Installed/\(encodedName)?assemblyGuid=\(AureliaSyncClient.pluginGUID)&repositoryUrl="
                + (AureliaSyncClient.repositoryURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? AureliaSyncClient.repositoryURL),
            method: "POST", body: Optional<String>.none
        )
    }

    private func get<T: Decodable>(path: String) async throws -> T {
        let request = try service.makeAuthenticatedRequest(path: path)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw AureliaSyncError.invalidResponse }
        return try decoder.decode(T.self, from: data)
    }

    private func send<T: Encodable>(path: String, method: String, body: T?) async throws {
        var request = try service.makeAuthenticatedRequest(path: path)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(body)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw AureliaSyncError.http((response as? HTTPURLResponse)?.statusCode ?? 0, String(data: data, encoding: .utf8))
        }
    }
}
