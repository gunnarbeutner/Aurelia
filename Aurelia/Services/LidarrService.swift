import Foundation
import Combine

nonisolated struct LidarrStatus: Decodable, Equatable, Sendable {
    let enabled: Bool
    let configured: Bool
    let healthy: Bool
    let canRequest: Bool
    let version: String?
    let message: String?
}

nonisolated struct LidarrAlbumResult: Decodable, Identifiable, Hashable, Sendable {
    let foreignAlbumId: String
    let foreignArtistId: String?
    let title: String
    let artistName: String
    let overview: String?
    let year: Int?
    let imageUrl: String?

    var id: String { foreignAlbumId }
}

nonisolated enum LidarrRequestState: String, Decodable, Sendable {
    case requested
    case searching
    case queued
    case downloading
    case waitingForJellyfin
    case available
    case failed
}

nonisolated struct LidarrRequest: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let foreignAlbumId: String
    let foreignArtistId: String?
    let title: String
    let artistName: String
    let state: LidarrRequestState
    let progress: Double?
    let jellyfinItemId: String?
    let errorMessage: String?
    let createdAt: Date
    let updatedAt: Date
}

nonisolated private struct LidarrRequestList: Decodable, Sendable {
    let items: [LidarrRequest]
}

nonisolated private struct CreateLidarrRequest: Encodable, Sendable {
    let foreignAlbumId: String
    let idempotencyKey: String
}

nonisolated enum LidarrServiceError: LocalizedError, Sendable {
    case invalidResponse
    case server(Int, String?)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The server returned an unexpected music request response."
        case .server(_, let message):
            return message ?? "The music request service is temporarily unavailable."
        }
    }
}

/// App-facing client for AureliaSync's constrained Lidarr endpoints.
@MainActor
final class LidarrService: ObservableObject {
    static let shared = LidarrService()

    @Published private(set) var status: LidarrStatus?
    @Published private(set) var searchResults: [LidarrAlbumResult] = []
    @Published private(set) var requests: [LidarrRequest] = []
    @Published private(set) var isSearching = false
    @Published private(set) var errorMessage: String?

    private let session: URLSession
    private let decoder: JSONDecoder

    init(session: URLSession = .shared) {
        self.session = session
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let ordinary = ISO8601DateFormatter()
            guard let date = ordinary.date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "Invalid ISO-8601 date"
                )
            }
            return date
        }
    }

    func refreshStatus() async {
        do {
            status = try await send(path: "AureliaSync/v1/lidarr/status", as: LidarrStatus.self)
            errorMessage = nil
        } catch {
            status = nil
            errorMessage = error.localizedDescription
        }
    }

    func search(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            searchResults = []
            return
        }

        isSearching = true
        defer { isSearching = false }
        do {
            var components = URLComponents()
            components.queryItems = [URLQueryItem(name: "query", value: trimmed)]
            let queryString = components.percentEncodedQuery.map { "?" + $0 } ?? ""
            searchResults = try await send(
                path: "AureliaSync/v1/lidarr/search" + queryString,
                as: [LidarrAlbumResult].self
            )
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            searchResults = []
            errorMessage = error.localizedDescription
        }
    }

    func clearSearch() {
        searchResults = []
    }

    func albums(forArtist foreignArtistId: String) async throws -> [LidarrAlbumResult] {
        let id = foreignArtistId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? foreignArtistId
        return try await send(
            path: "AureliaSync/v1/lidarr/artists/" + id + "/albums",
            as: [LidarrAlbumResult].self
        )
    }

    @discardableResult
    func request(_ album: LidarrAlbumResult) async throws -> LidarrRequest {
        try await submitRequest(foreignAlbumId: album.foreignAlbumId)
    }

    @discardableResult
    func retry(_ failedRequest: LidarrRequest) async throws -> LidarrRequest {
        try await submitRequest(foreignAlbumId: failedRequest.foreignAlbumId)
    }

    private func submitRequest(foreignAlbumId: String) async throws -> LidarrRequest {
        let body = CreateLidarrRequest(
            foreignAlbumId: foreignAlbumId,
            idempotencyKey: UUID().uuidString.lowercased()
        )
        let request = try await send(
            path: "AureliaSync/v1/lidarr/requests",
            method: "POST",
            body: body,
            as: LidarrRequest.self
        )
        requests.removeAll { $0.id == request.id || $0.foreignAlbumId == request.foreignAlbumId }
        requests.insert(request, at: 0)
        errorMessage = nil
        return request
    }

    func refreshRequests() async {
        do {
            let response = try await send(
                path: "AureliaSync/v1/lidarr/requests",
                as: LidarrRequestList.self
            )
            requests = Self.latestRequestPerAlbum(response.items)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func request(for foreignAlbumId: String) -> LidarrRequest? {
        requests.first { $0.foreignAlbumId.caseInsensitiveCompare(foreignAlbumId) == .orderedSame }
    }

    private static func latestRequestPerAlbum(_ requests: [LidarrRequest]) -> [LidarrRequest] {
        var seenAlbums = Set<String>()
        return requests
            .sorted {
                if $0.createdAt == $1.createdAt { return $0.updatedAt > $1.updatedAt }
                return $0.createdAt > $1.createdAt
            }
            .filter { seenAlbums.insert($0.foreignAlbumId.lowercased()).inserted }
    }

    private func send<Response: Decodable>(path: String, as type: Response.Type) async throws -> Response {
        let request = try JellyfinService.shared.makeAuthenticatedRequest(path: path)
        return try await perform(request, as: type)
    }

    private func send<Body: Encodable, Response: Decodable>(
        path: String,
        method: String,
        body: Body,
        as type: Response.Type
    ) async throws -> Response {
        var request = try JellyfinService.shared.makeAuthenticatedRequest(path: path)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request, as: type)
    }

    private func perform<Response: Decodable>(
        _ request: URLRequest,
        as type: Response.Type
    ) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LidarrServiceError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            throw LidarrServiceError.server(http.statusCode, message)
        }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw LidarrServiceError.invalidResponse
        }
    }
}
