//
//  JellyfinService.swift
//  Aurelia
//
//  Core service for Jellyfin API interactions including Quick Connect authentication
//  and music streaming. Optimized for iOS 26.
//

import Foundation
import Combine
import UIKit
import SwiftUI
import os.log

/// Main service class for all Jellyfin API interactions
/// Handles authentication, music library fetching, and streaming
class JellyfinService: ObservableObject {
    static let shared = JellyfinService()

    private let logger = Logger(subsystem: "de.beutner.Aurelia", category: "JellyfinService")

    // MARK: - Properties
    // Keychain survives app removal, so a reinstall can restore the server and
    // authenticated Jellyfin session without onboarding again.
    @Published var baseURL: String = KeychainService.shared.getServerURL() ?? "" {
        didSet {
            try? KeychainService.shared.saveServerURL(baseURL)
        }
    }
    private let clientName = "Aurelia"
    private let clientVersion = "1.0.0"
    private static let deviceIdKey = "AureliaDeviceId"
    let deviceId: String = {
        if let existing = UserDefaults.standard.string(forKey: deviceIdKey) {
            return existing
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: deviceIdKey)
        return newId
    }()

    @Published var isAuthenticated = false
    @Published var currentUser: User?

    private var cancellables = Set<AnyCancellable>()
    private let session: URLSession

    /// Metadata needed to fully reconstruct the local library and its
    /// relationships without issuing follow-up requests from individual views.
    private static let libraryMetadataFields = [
        "BasicSyncInfo", "UserData", "Overview",
        "Genres", "SortName", "ParentId", "AlbumId", "ArtistItems",
        "AlbumArtists", "GenreItems", "DateCreated", "PrimaryImageAspectRatio",
        "ChildCount"
    ].joined(separator: ",")
    private static let libraryRequestTimeout: TimeInterval = 90

    // MARK: - Quick Connect Properties
    struct QuickConnectResponse: Codable {
        let Code: String
        let Secret: String
    }

    struct QuickConnectStatus: Codable {
        let Authenticated: Bool
        let Secret: String
        let Code: String
        let DeviceId: String?
        let DeviceName: String?
        let AppName: String?
        let AppVersion: String?
        let DateAdded: String?
    }

    struct User: Codable {
        let Id: String
        let Name: String
    }

    /// A user the server is willing to name on a login screen.
    ///
    /// Jellyfin publishes these per-user ("Hide this user from login screens"),
    /// so an empty list is a legitimate answer meaning "make them type it".
    struct PublicUser: Codable, Identifiable, Sendable, Equatable {
        let Id: String
        let Name: String
        let PrimaryImageTag: String?
        let HasPassword: Bool?

        var id: String { Id }

        /// Servers may omit the field; assume a password is needed rather than
        /// walking someone into a failed sign-in.
        var requiresPassword: Bool { HasPassword ?? true }
    }

    struct AuthenticationResult: Codable {
        let User: User?
        let AccessToken: String?
        let ServerId: String?
    }

    struct PlaylistCreationResult: Codable {
        let Id: String
    }

    // MARK: - Initialization
    init() {
        // Configure URLSession for network optimization
        let config = URLSessionConfiguration.default
        config.allowsCellularAccess = true
        config.timeoutIntervalForRequest = 10 // Fail faster for better UX
        config.timeoutIntervalForResource = 300 // 5 minutes for streaming
        config.waitsForConnectivity = false // Fail immediately when no network
        config.sessionSendsLaunchEvents = true // Background support

        self.session = URLSession(configuration: config)

        // Check for stored credentials and validate session
        if KeychainService.shared.getAccessToken() != nil && !baseURL.isEmpty {
            // Start with optimistic authentication, then validate
            self.isAuthenticated = true
            
            // Validate session in background
            Task {
                await validateSessionOnLaunch()
            }
        }
    }

    // MARK: - Quick Connect Authentication

    /// Initiates Quick Connect flow
    /// Returns the 6-character code for user to enter on Jellyfin server
    func initiateQuickConnect() async throws -> (code: String, secret: String) {
        let url = URL(string: "\(baseURL)/QuickConnect/Initiate")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(generateAuthorizationHeader(token: nil), forHTTPHeaderField: "X-Emby-Authorization")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw JellyfinError.invalidResponse
        }

        let quickConnectResponse = try SafeJellyfinDecoder.decode(QuickConnectResponse.self, from: data)
        return (code: quickConnectResponse.Code, secret: quickConnectResponse.Secret)
    }

    /// Polls Quick Connect status
    /// Returns true when authenticated with access token stored
    func pollQuickConnect(secret: String) async throws -> Bool {
        let url = URL(string: "\(baseURL)/QuickConnect/Connect?secret=\(secret)")!

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(generateAuthorizationHeader(token: nil), forHTTPHeaderField: "X-Emby-Authorization")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw JellyfinError.invalidResponse
        }

        let status = try SafeJellyfinDecoder.decode(QuickConnectStatus.self, from: data)

        if status.Authenticated {
            // Exchange the secret for an access token
            let authorizeURL = URL(string: "\(baseURL)/Users/AuthenticateWithQuickConnect")!

            var authorizeRequest = URLRequest(url: authorizeURL)
            authorizeRequest.httpMethod = "POST"
            authorizeRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            authorizeRequest.setValue(generateAuthorizationHeader(token: nil), forHTTPHeaderField: "X-Emby-Authorization")

            let body = ["Secret": status.Secret]
            authorizeRequest.httpBody = try JSONEncoder().encode(body)

            let (authData, authResponse) = try await session.data(for: authorizeRequest)

            guard let httpAuthResponse = authResponse as? HTTPURLResponse,
                  httpAuthResponse.statusCode == 200 else {
                throw JellyfinError.invalidResponse
            }

            // Parse the authentication response
            if let authResult = try? JSONDecoder().decode(AuthenticationResult.self, from: authData),
               let token = authResult.AccessToken {
                // Store token securely
                try KeychainService.shared.saveServerURL(baseURL)
                try KeychainService.shared.saveAccessToken(token)
                self.isAuthenticated = true
                self.currentUser = authResult.User

                // Store user ID
                if let userId = authResult.User?.Id {
                    try KeychainService.shared.saveUserID(userId)
                }

                return true
            }
        }

        return false
    }

    /// Authenticate with username and password
    func authenticateByName(username: String, password: String) async throws {
        let url = URL(string: "\(baseURL)/Users/AuthenticateByName")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(generateAuthorizationHeader(token: nil), forHTTPHeaderField: "X-Emby-Authorization")

        let body: [String: String] = ["Username": username, "Pw": password]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw JellyfinError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            let authResult = try JSONDecoder().decode(AuthenticationResult.self, from: data)
            if let token = authResult.AccessToken {
                try KeychainService.shared.saveServerURL(baseURL)
                try KeychainService.shared.saveAccessToken(token)
                self.isAuthenticated = true
                self.currentUser = authResult.User

                if let userId = authResult.User?.Id {
                    try KeychainService.shared.saveUserID(userId)
                }

                // Sync to watch
                PhoneConnectivityManager.shared.syncCredentialsToWatch()
            } else {
                throw JellyfinError.invalidResponse
            }
        case 401:
            throw JellyfinError.unauthorized
        default:
            throw JellyfinError.invalidResponse
        }
    }

    /// Users the server advertises on its login screen, newest Jellyfin's
    /// equivalent of the account picker.
    ///
    /// Returns an empty list rather than throwing: a server with every user
    /// hidden, an older server without the endpoint, and an unreachable one all
    /// mean the same thing to the caller — fall back to typing a name.
    func fetchPublicUsers() async -> [PublicUser] {
        guard let url = URL(string: "\(baseURL)/Users/Public") else { return [] }

        var request = URLRequest(url: url)
        request.setValue(generateAuthorizationHeader(token: nil), forHTTPHeaderField: "X-Emby-Authorization")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                logger.info("Public users unavailable; falling back to manual entry")
                return []
            }
            let users = try JSONDecoder().decode([PublicUser].self, from: data)
            logger.info("Server published \(users.count) users for the login screen")
            return users
        } catch {
            logger.info("Could not read public users: \(error.localizedDescription)")
            return []
        }
    }

    /// Avatar for a user on the login screen. Unauthenticated, like the list.
    func userImageURL(userId: String, imageTag: String, size: Int = 200) -> URL? {
        var components = URLComponents(string: "\(baseURL)/Users/\(userId)/Images/Primary")
        components?.queryItems = [
            URLQueryItem(name: "tag", value: imageTag),
            URLQueryItem(name: "maxWidth", value: "\(size)"),
            URLQueryItem(name: "maxHeight", value: "\(size)"),
            URLQueryItem(name: "quality", value: "90")
        ]
        return components?.url
    }

    /// Check server connectivity (returns true if server is reachable)
    func checkServerConnectivity() async throws -> Bool {
        let url = URL(string: "\(baseURL)/System/Info/Public")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            return false
        }
        return true
    }

    /// Check if Quick Connect is enabled on the server
    func checkQuickConnect() async throws -> Bool {
        let url = URL(string: "\(baseURL)/QuickConnect/Enabled")!

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            return false
        }

        // The response should be a simple boolean
        if let responseString = String(data: data, encoding: .utf8),
           let isEnabled = Bool(responseString.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return isEnabled
        }

        return false
    }

    // MARK: - User Management

    /// Fetches current user information using access token
    private func fetchCurrentUser(token: String) async throws {
        let url = URL(string: "\(baseURL)/Users/Me")!

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(generateAuthorizationHeader(token: token), forHTTPHeaderField: "X-Emby-Authorization")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw JellyfinError.invalidResponse
        }
        
        // Handle specific HTTP status codes for authentication
        switch httpResponse.statusCode {
        case 200:
            // Success - decode user
            let user = try SafeJellyfinDecoder.decode(User.self, from: data)
            self.currentUser = user
            
            try KeychainService.shared.saveUserID(user.Id)
            
        case 401:
            throw JellyfinError.unauthorized
            
        case 403:
            throw JellyfinError.forbidden
            
        default:
            throw JellyfinError.invalidResponse
        }
    }

    // Catalog synchronization is intentionally absent here. AureliaSync is
    // the sole transport for artists, albums, tracks, playlists and genres.

    /// Search for music items across all types
    func searchMusic(query: String, parentId: String? = nil) async throws -> [BaseItemDto] {
        guard let token = KeychainService.shared.getAccessToken(),
              let userId = KeychainService.shared.getUserID() else {
            throw JellyfinError.notAuthenticated
        }

        var components = URLComponents(string: "\(baseURL)/Users/\(userId)/Items")!
        components.queryItems = [
            URLQueryItem(name: "searchTerm", value: query),
            URLQueryItem(name: "IncludeItemTypes", value: "MusicArtist,MusicAlbum,Audio,Playlist"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending"),
            URLQueryItem(name: "Fields", value: "BasicSyncInfo,MediaSources"),
            URLQueryItem(name: "Limit", value: "50")
        ]

        // Add parent filter if provided (for library filtering)
        if let parentId = parentId {
            components.queryItems?.append(URLQueryItem(name: "ParentId", value: parentId))
        }

        let url = try buildURL(from: components)
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(generateAuthorizationHeader(token: token), forHTTPHeaderField: "X-Emby-Authorization")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw JellyfinError.invalidResponse
        }

        let itemsResponse = try SafeJellyfinDecoder.decode(ItemsResponse.self, from: data)
        return itemsResponse.Items
    }

    // MARK: - Streaming

    /// Generates streaming URL for audio playback
    /// Uses DIRECT streaming (no transcoding) for maximum reliability
    /// Serves original audio files - AVPlayer handles all common formats natively
    func getStreamingURL(for itemId: String) -> URL? {
        return getStreamingURL(for: itemId, bitrate: 128)
    }

    /// Generates streaming URL with HTTP transcoding support (matches JellyJam's proven approach)
    /// Uses /stream endpoint with transcoding parameters for maximum compatibility
    func getStreamingURL(for itemId: String, bitrate: Int) -> URL? {
        // Validate item ID
        guard !itemId.isEmpty else {
            logger.error("Empty item ID provided for streaming URL")
            return nil
        }

        guard let token = KeychainService.shared.getAccessToken(), !token.isEmpty else {
            logger.error("Failed to get streaming URL: No access token")
            return nil
        }

        // Ensure base URL is valid
        let cleanBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanBaseURL.isEmpty else {
            logger.error("Base URL is empty")
            return nil
        }

        // Use /stream endpoint with transcoding parameters (same as JellyJam)
        // This allows the server to transcode when needed while still being reliable
        let normalizedBaseURL = cleanBaseURL.hasSuffix("/") ? String(cleanBaseURL.dropLast()) : cleanBaseURL
        let streamPath = "/Audio/\(itemId)/stream"
        let fullURLString = normalizedBaseURL + streamPath

        guard var components = URLComponents(string: fullURLString) else {
            logger.error("Failed to create URL components for streaming: \(fullURLString)")
            return nil
        }

        // Build query items with proper encoding (matches JellyJam parameters)
        components.queryItems = [
            URLQueryItem(name: "static", value: "true"),
            URLQueryItem(name: "mediaSourceId", value: itemId),
            URLQueryItem(name: "api_key", value: token),
            URLQueryItem(name: "MaxStreamingBitrate", value: "\(bitrate * 1000)"), // Convert kbps to bps
            URLQueryItem(name: "AudioCodec", value: "mp3"),
            URLQueryItem(name: "Container", value: "mp3,aac"),
            URLQueryItem(name: "TranscodingContainer", value: "mp3"),
            URLQueryItem(name: "TranscodingProtocol", value: "http")
        ]

        // Ensure percent encoding is applied
        components.percentEncodedQuery = components.percentEncodedQuery

        guard let url = components.url else {
            logger.error("Failed to generate final streaming URL")
            return nil
        }

        logger.info("Generated streaming URL for item \(itemId) at \(bitrate)kbps")
        logger.info("  → Using /stream endpoint with HTTP transcoding support")
        return url
    }

    /// Generates download URL for offline storage
    /// Returns the original file without transcoding for offline playback
    func getDownloadURL(for itemId: String) -> URL? {
        // Validate item ID
        guard !itemId.isEmpty else {
            logger.error("Empty item ID provided for download URL")
            return nil
        }

        guard let token = KeychainService.shared.getAccessToken(), !token.isEmpty else {
            logger.error("Failed to get download URL: No access token")
            return nil
        }

        // Ensure base URL is valid
        let cleanBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanBaseURL.isEmpty else {
            logger.error("Base URL is empty")
            return nil
        }

        // Use /Items/{itemId}/Download endpoint for original file
        let normalizedBaseURL = cleanBaseURL.hasSuffix("/") ? String(cleanBaseURL.dropLast()) : cleanBaseURL
        let downloadPath = "/Items/\(itemId)/Download"
        let fullURLString = normalizedBaseURL + downloadPath

        guard var components = URLComponents(string: fullURLString) else {
            logger.error("Failed to create URL components for download: \(fullURLString)")
            return nil
        }

        // Add API key for authentication
        components.queryItems = [
            URLQueryItem(name: "api_key", value: token)
        ]

        guard let url = components.url else {
            logger.error("Failed to generate final download URL")
            return nil
        }

        logger.info("Generated download URL for item \(itemId)")
        logger.info("  → Using /Download endpoint for original file")
        return url
    }

    /// Generates a download URL honouring the user's download quality.
    ///
    /// Anything but `.original` goes through `/Audio/{id}/universal`, which
    /// negotiates rather than transcodes blindly: a source already inside the
    /// requested bitrate is served untouched, so a 192 kbps MP3 asked for at
    /// 320 is not re-encoded into a larger, worse file.
    func getDownloadURL(for itemId: String, quality: DownloadQuality) -> URL? {
        guard quality != .original else {
            return getDownloadURL(for: itemId)
        }

        guard !itemId.isEmpty else {
            logger.error("Empty item ID provided for download URL")
            return nil
        }

        guard let token = KeychainService.shared.getAccessToken(), !token.isEmpty else {
            logger.error("Failed to get download URL: No access token")
            return nil
        }

        let cleanBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanBaseURL.isEmpty else {
            logger.error("Base URL is empty")
            return nil
        }

        let normalizedBaseURL = cleanBaseURL.hasSuffix("/") ? String(cleanBaseURL.dropLast()) : cleanBaseURL
        guard var components = URLComponents(string: normalizedBaseURL + "/Audio/\(itemId)/universal") else {
            logger.error("Failed to create URL components for download: \(itemId)")
            return nil
        }

        var queryItems = [
            URLQueryItem(name: "api_key", value: token),
            URLQueryItem(name: "DeviceId", value: deviceId),
            URLQueryItem(name: "MaxStreamingBitrate", value: "\(quality.bitrate * 1000)"),
            // Containers this client can play back from a local file. The
            // server direct-streams when the source already qualifies.
            URLQueryItem(name: "Container", value: "mp3,aac,m4a,mp4"),
            URLQueryItem(name: "AudioCodec", value: "mp3"),
            URLQueryItem(name: "TranscodingContainer", value: "mp3"),
            URLQueryItem(name: "TranscodingProtocol", value: "http")
        ]
        if let userId = KeychainService.shared.getUserID() {
            queryItems.append(URLQueryItem(name: "UserId", value: userId))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            logger.error("Failed to generate final download URL")
            return nil
        }

        logger.info("Generated download URL for item \(itemId) at \(quality.bitrate)kbps")
        logger.info("  → Using /universal endpoint, transcoding only if the source exceeds it")
        return url
    }

    // MARK: - Playlist Management

    /// Create a new playlist
    func createPlaylist(name: String, trackIds: [String] = []) async throws -> String {
        guard let token = KeychainService.shared.getAccessToken(),
              let userId = KeychainService.shared.getUserID() else {
            throw JellyfinError.notAuthenticated
        }

        // Build URL with query parameters
        var components = URLComponents(string: "\(baseURL)/Playlists")!
        var queryItems = [
            URLQueryItem(name: "Name", value: name),
            URLQueryItem(name: "MediaType", value: "Audio"),
            URLQueryItem(name: "UserId", value: userId)
        ]

        // Only add Ids if we have tracks to add
        if !trackIds.isEmpty {
            queryItems.append(URLQueryItem(name: "Ids", value: trackIds.joined(separator: ",")))
        }

        components.queryItems = queryItems

        guard let url = components.url else {
            throw JellyfinError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(generateAuthorizationHeader(token: token), forHTTPHeaderField: "X-Emby-Authorization")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("❌ Invalid HTTP response")
            throw JellyfinError.invalidResponse
        }

        logger.info("📋 Playlist creation response: status=\(httpResponse.statusCode)")

        // Log response body for debugging
        if let responseString = String(data: data, encoding: .utf8) {
            logger.info("📋 Response body: \(responseString)")
        }

        guard httpResponse.statusCode == 200 else {
            logger.error("❌ Unexpected status code: \(httpResponse.statusCode)")
            throw JellyfinError.invalidResponse
        }

        // Parse response to get playlist ID
        let result = try SafeJellyfinDecoder.decode(PlaylistCreationResult.self, from: data)
        logger.info("✅ Created playlist: \(name) with ID: \(result.Id)")
        return result.Id
    }

    /// Add tracks to a playlist
    func addToPlaylist(playlistId: String, trackIds: [String]) async throws {
        guard let token = KeychainService.shared.getAccessToken() else {
            throw JellyfinError.notAuthenticated
        }

        var components = URLComponents(string: "\(baseURL)/Playlists/\(playlistId)/Items")!
        components.queryItems = [
            URLQueryItem(name: "Ids", value: trackIds.joined(separator: ","))
        ]

        guard let url = components.url else {
            throw JellyfinError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(generateAuthorizationHeader(token: token), forHTTPHeaderField: "X-Emby-Authorization")

        logger.info("📋 Adding \(trackIds.count) tracks to playlist \(playlistId)")
        logger.info("📋 Request URL: \(url.absoluteString)")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("❌ Invalid HTTP response for addToPlaylist")
            throw JellyfinError.invalidResponse
        }

        logger.info("📋 Add to playlist response: status=\(httpResponse.statusCode)")

        // Log response body for debugging
        if let responseString = String(data: data, encoding: .utf8), !responseString.isEmpty {
            logger.info("📋 Response body: \(responseString)")
        }

        guard httpResponse.statusCode == 204 || httpResponse.statusCode == 200 else {
            logger.error("❌ Unexpected status code when adding to playlist: \(httpResponse.statusCode)")
            throw JellyfinError.invalidResponse
        }

        logger.info("✅ Added \(trackIds.count) tracks to playlist \(playlistId)")
    }

    /// Remove tracks from a playlist
    func removeFromPlaylist(playlistId: String, entryIds: [String]) async throws {
        guard let token = KeychainService.shared.getAccessToken() else {
            throw JellyfinError.notAuthenticated
        }

        var components = URLComponents(string: "\(baseURL)/Playlists/\(playlistId)/Items")!
        components.queryItems = [
            URLQueryItem(name: "EntryIds", value: entryIds.joined(separator: ","))
        ]

        guard let url = components.url else {
            throw JellyfinError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(generateAuthorizationHeader(token: token), forHTTPHeaderField: "X-Emby-Authorization")

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 204 || httpResponse.statusCode == 200 else {
            throw JellyfinError.invalidResponse
        }

        logger.info("✅ Removed \(entryIds.count) tracks from playlist \(playlistId)")
    }

    // MARK: - Favorites Management

    /// Mark an item as favorite
    func markFavorite(itemId: String) async throws {
        guard let token = KeychainService.shared.getAccessToken(),
              let userId = KeychainService.shared.getUserID() else {
            throw JellyfinError.notAuthenticated
        }

        guard let url = URL(string: "\(baseURL)/Users/\(userId)/FavoriteItems/\(itemId)") else {
            throw JellyfinError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(generateAuthorizationHeader(token: token), forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw JellyfinError.invalidResponse
        }
    }

    /// Remove item from favorites
    func unmarkFavorite(itemId: String) async throws {
        guard let token = KeychainService.shared.getAccessToken(),
              let userId = KeychainService.shared.getUserID() else {
            throw JellyfinError.notAuthenticated
        }

        guard let url = URL(string: "\(baseURL)/Users/\(userId)/FavoriteItems/\(itemId)") else {
            throw JellyfinError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(generateAuthorizationHeader(token: token), forHTTPHeaderField: "X-Emby-Authorization")

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw JellyfinError.invalidResponse
        }
    }

    // MARK: - Discovery and Instant Mix

    /// Fetches Jellyfin's Instant Mix for any playable library item. AudioMuse-AI
    /// overrides this standard route when its plugin is installed.
    func fetchInstantMix(itemId: String, limit: Int = 50) async throws -> [BaseItemDto] {
        guard let token = authToken, let userId = currentUserId else {
            throw JellyfinError.notAuthenticated
        }

        var components = try buildURLComponents(path: "Items/\(itemId)/InstantMix")
        components.queryItems = Self.instantMixQueryItems(userId: userId, limit: limit)
        var request = try authenticatedRequest(from: components, token: token)
        // AudioMuse computes recommendations on demand and can legitimately
        // take longer than ordinary Jellyfin metadata requests, particularly
        // while its library analysis is running.
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try SafeJellyfinDecoder.decode(ItemsResponse.self, from: data).Items
    }

    /// Fetch the signed-in user's cross-client playback state. Jellyfin stores
    /// DatePlayed per user and item, so this is shared by every client reporting
    /// playback for the same account rather than being local to this device.
    func fetchRecentlyPlayedTracks(limit: Int) async throws -> [BaseItemDto] {
        guard let token = authToken, let userId = currentUserId else {
            throw JellyfinError.notAuthenticated
        }

        var components = try buildURLComponents(path: "Users/\(userId)/Items")
        components.queryItems = Self.recentlyPlayedQueryItems(userId: userId, limit: limit)
        let request = try authenticatedRequest(from: components, token: token)
        let (data, response) = try await session.data(for: request)
        try validate(response: response)
        return try SafeJellyfinDecoder.decode(ItemsResponse.self, from: data).Items
    }

    func fetchRandomTracks(limit: Int) async throws -> [BaseItemDto] {
        guard let token = authToken, let userId = currentUserId else {
            throw JellyfinError.notAuthenticated
        }

        var components = try buildURLComponents(path: "Users/\(userId)/Items")
        components.queryItems = discoveryQueryItems(userId: userId, limit: limit) + [
            URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SortBy", value: "Random")
        ]
        let request = try authenticatedRequest(from: components, token: token)
        let (data, response) = try await session.data(for: request)
        try validate(response: response)
        return try SafeJellyfinDecoder.decode(ItemsResponse.self, from: data).Items
    }

    func fetchAudioMuseInfo() async throws -> AudioMusePluginInfo {
        let (data, response) = try await fetchAudioMuse(path: "info")
        try validate(response: response, recognizeNotFound: true)
        return try SafeJellyfinDecoder.decode(AudioMusePluginInfo.self, from: data)
    }

    func checkAudioMuseHealth() async throws -> Bool {
        let (_, response) = try await fetchAudioMuse(path: "health")
        guard let httpResponse = response as? HTTPURLResponse else {
            throw JellyfinError.invalidResponse
        }
        if httpResponse.statusCode == 404 { throw JellyfinError.notFound }
        return (200...299).contains(httpResponse.statusCode)
    }

    func fetchActiveAudioMuseTask() async throws -> AudioMuseTaskStatus? {
        let (data, response) = try await fetchAudioMuse(path: "active_tasks")
        try validate(response: response, recognizeNotFound: true)

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              !object.isEmpty else {
            return nil
        }
        let status = try SafeJellyfinDecoder.decode(AudioMuseTaskStatus.self, from: data)
        return status.isActive ? status : nil
    }

    private func fetchAudioMuse(path: String) async throws -> (Data, URLResponse) {
        guard let token = authToken else { throw JellyfinError.notAuthenticated }
        let components = try buildURLComponents(path: "AudioMuseAI/\(path)")
        let request = try authenticatedRequest(from: components, token: token)
        return try await session.data(for: request)
    }

    private func authenticatedRequest(from components: URLComponents, token: String) throws -> URLRequest {
        var request = URLRequest(url: try buildURL(from: components))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(generateAuthorizationHeader(token: token), forHTTPHeaderField: "X-Emby-Authorization")
        return request
    }

    static func instantMixQueryItems(userId: String, limit: Int) -> [URLQueryItem] {
        let fields = [
            "PrimaryImageAspectRatio",
            "MediaSources"
        ]

        return [
            URLQueryItem(name: "UserId", value: userId),
            URLQueryItem(name: "Limit", value: String(limit))
        ] + fields.map {
            URLQueryItem(name: "Fields", value: $0)
        } + [
            URLQueryItem(name: "EnableImages", value: "true"),
            URLQueryItem(name: "ImageTypeLimit", value: "1"),
            URLQueryItem(name: "EnableImageTypes", value: "Primary"),
            URLQueryItem(name: "EnableUserData", value: "true")
        ]
    }

    static func recentlyPlayedQueryItems(userId: String, limit: Int) -> [URLQueryItem] {
        [
            URLQueryItem(name: "UserId", value: userId),
            URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SortBy", value: "DatePlayed"),
            URLQueryItem(name: "SortOrder", value: "Descending"),
            URLQueryItem(name: "IsPlayed", value: "true"),
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "Fields", value: "PrimaryImageAspectRatio,BasicSyncInfo,MediaSources,AlbumPrimaryImageTag,UserData"),
            URLQueryItem(name: "EnableImages", value: "true"),
            URLQueryItem(name: "ImageTypeLimit", value: "1"),
            URLQueryItem(name: "EnableImageTypes", value: "Primary"),
            URLQueryItem(name: "EnableUserData", value: "true"),
            URLQueryItem(name: "EnableTotalRecordCount", value: "false")
        ]
    }

    private func discoveryQueryItems(userId: String, limit: Int) -> [URLQueryItem] {
        [
            URLQueryItem(name: "UserId", value: userId),
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "Fields", value: "PrimaryImageAspectRatio,BasicSyncInfo,MediaSources,AlbumPrimaryImageTag,UserData"),
            URLQueryItem(name: "EnableImages", value: "true"),
            URLQueryItem(name: "ImageTypeLimit", value: "1"),
            URLQueryItem(name: "EnableImageTypes", value: "Primary"),
            URLQueryItem(name: "EnableUserData", value: "true")
        ]
    }

    /// How far the server's clock runs ahead of this device's, learned from
    /// the `Date` header every response already carries.
    ///
    /// Sync watermarks are sent back as `MinDateLastSaved` and compared against
    /// the server's own timestamps, so a watermark taken from the local clock
    /// silently loses every change made in the gap when this device runs ahead.
    private(set) var serverClockOffset: TimeInterval = 0

    /// Now, as the server would put it.
    var serverNow: Date {
        Date().addingTimeInterval(serverClockOffset)
    }

    private func noteServerClock(from response: HTTPURLResponse) {
        guard let header = response.value(forHTTPHeaderField: "Date"),
              let offset = Self.clockOffset(fromDateHeader: header, now: Date()) else { return }
        serverClockOffset = offset
    }

    /// Parsed rather than trusted: a header we cannot read must leave the offset
    /// alone, since a wrong offset is worse than none.
    nonisolated static func clockOffset(fromDateHeader header: String, now: Date) -> TimeInterval? {
        guard let serverDate = httpDateFormatter.date(from: header) else { return nil }
        return serverDate.timeIntervalSince(now)
    }

    nonisolated(unsafe) private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    private func validate(
        response: URLResponse,
        data: Data? = nil,
        recognizeNotFound: Bool = false
    ) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw JellyfinError.invalidResponse
        }
        noteServerClock(from: httpResponse)
        switch httpResponse.statusCode {
        case 200...299:
            return
        case 401:
            throw JellyfinError.unauthorized
        case 403:
            throw JellyfinError.forbidden
        case 404 where recognizeNotFound:
            throw JellyfinError.notFound
        default:
            throw JellyfinError.httpError(
                statusCode: httpResponse.statusCode,
                message: serverErrorMessage(from: data)
            )
        }
    }

    private func serverErrorMessage(from data: Data?) -> String? {
        guard let data, !data.isEmpty else { return nil }

        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["Message", "message", "Detail", "detail", "Title", "title", "Error", "error"] {
                if let value = object[key] as? String,
                   let message = sanitizedServerMessage(value) {
                    return message
                }
            }
        }

        guard let text = String(data: data, encoding: .utf8),
              !text.localizedCaseInsensitiveContains("<html") else {
            return nil
        }
        return sanitizedServerMessage(text)
    }

    private func sanitizedServerMessage(_ value: String) -> String? {
        let normalized = value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(240))
    }

    // MARK: - Image Upload

    /// Upload an image to a Jellyfin item (artist, album, etc.)
    func uploadImage(itemId: String, imageData: Data, contentType: String = "image/jpeg") async throws {
        guard let token = KeychainService.shared.getAccessToken() else {
            throw JellyfinError.notAuthenticated
        }

        let url = URL(string: "\(baseURL)/Items/\(itemId)/Images/Primary")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(generateAuthorizationHeader(token: token), forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = imageData

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw JellyfinError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: responseData, encoding: .utf8) ?? "no body"
            logger.error("Image upload failed: HTTP \(httpResponse.statusCode) - \(body)")
            switch httpResponse.statusCode {
            case 401: throw JellyfinError.unauthorized
            case 403: throw JellyfinError.forbidden
            default: throw JellyfinError.invalidResponse
            }
        }
    }

    // MARK: - Playback Reporting

    /// Report that playback has started for a track
    func reportPlaybackStart(itemId: String, positionTicks: Int64 = 0) async {
        guard let token = KeychainService.shared.getAccessToken() else { return }
        let body: [String: Any] = [
            "ItemId": itemId,
            "PositionTicks": positionTicks,
            "PlayMethod": "DirectStream",
            "IsPaused": false,
            "IsMuted": false,
            "RepeatMode": "RepeatNone"
        ]
        await postPlaybackReport(path: "Sessions/Playing", body: body, token: token)
    }

    /// Report playback progress (called every ~10s)
    func reportPlaybackProgress(itemId: String, positionTicks: Int64, isPaused: Bool) async {
        guard let token = KeychainService.shared.getAccessToken() else { return }
        let body: [String: Any] = [
            "ItemId": itemId,
            "PositionTicks": positionTicks,
            "PlayMethod": "DirectStream",
            "IsPaused": isPaused,
            "IsMuted": false,
            "RepeatMode": "RepeatNone"
        ]
        await postPlaybackReport(path: "Sessions/Playing/Progress", body: body, token: token)
    }

    /// Report that playback has stopped
    func reportPlaybackStopped(itemId: String, positionTicks: Int64) async {
        guard let token = KeychainService.shared.getAccessToken() else { return }
        let body: [String: Any] = [
            "ItemId": itemId,
            "PositionTicks": positionTicks,
            "PlayMethod": "DirectStream"
        ]
        await postPlaybackReport(path: "Sessions/Playing/Stopped", body: body, token: token)
    }

    private func postPlaybackReport(path: String, body: [String: Any], token: String) async {
        guard let url = URL(string: "\(baseURL)/\(path)"),
              let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(generateAuthorizationHeader(token: token), forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                logger.warning("Playback report to \(path) returned HTTP \(http.statusCode)")
            }
        } catch {
            logger.warning("Playback report to \(path) failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Helper Methods

    private func buildURLComponents(path: String) throws -> URLComponents {
        guard let components = URLComponents(string: "\(baseURL)/\(path)") else {
            throw JellyfinError.invalidURL
        }
        return components
    }

    private func buildURL(from components: URLComponents) throws -> URL {
        guard let url = components.url else {
            throw JellyfinError.invalidURL
        }
        return url
    }

    /// Authenticated request builder for companion Jellyfin plugins. Catalog
    /// synchronization itself lives in AureliaSync; keeping authentication
    /// construction here avoids duplicating Jellyfin's header format.
    func makeAuthenticatedRequest(path: String) throws -> URLRequest {
        guard let token = authToken else { throw JellyfinError.notAuthenticated }
        guard !path.contains("..") else { throw JellyfinError.invalidURL }
        var request = URLRequest(url: try buildURL(from: buildURLComponents(path: path)))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(generateAuthorizationHeader(token: token), forHTTPHeaderField: "X-Emby-Authorization")
        return request
    }

    private static func jellyfinDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    func makeLibraryWebSocketRequest(path: String = "socket") throws -> URLRequest {
        guard let token = authToken else { throw JellyfinError.notAuthenticated }
        guard path == "socket" || path == "embywebsocket" else {
            throw JellyfinError.invalidURL
        }
        var components = try buildURLComponents(path: path)
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.queryItems = [
            URLQueryItem(name: "api_key", value: token),
            URLQueryItem(name: "deviceId", value: deviceId)
        ]
        var request = URLRequest(url: try buildURL(from: components))
        request.setValue(
            generateAuthorizationHeader(token: token),
            forHTTPHeaderField: "X-Emby-Authorization"
        )
        return request
    }

    /// Generates authorization header for Jellyfin API
    private func generateAuthorizationHeader(token: String?) -> String {
        let deviceName = UIDevice.current.model // "iPhone" or "iPad"
        if let token = token {
            return "MediaBrowser Token=\"\(token)\", Client=\"\(clientName)\", Device=\"\(deviceName)\", DeviceId=\"\(deviceId)\", Version=\"\(clientVersion)\""
        } else {
            return "MediaBrowser Client=\"\(clientName)\", Device=\"\(deviceName)\", DeviceId=\"\(deviceId)\", Version=\"\(clientVersion)\""
        }
    }

    /// Validates current session
    func validateSession() async throws -> Bool {
        guard let token = authToken else { return false }
        do {
            try await fetchCurrentUser(token: token)
            return true
        } catch {
            return false
        }
    }
    
    /// Validates session on app launch and handles authentication state
    @MainActor
    private func validateSessionOnLaunch() async {
        guard let token = KeychainService.shared.getAccessToken() else {
            // No token - stay unauthenticated
            self.isAuthenticated = false
            return
        }
        
        do {
            // Use the existing fetchCurrentUser method to validate
            try await fetchCurrentUser(token: token)
            // Session is valid - stay authenticated
            logger.info("✅ Session validated successfully on app launch")
        } catch {
            // Handle specific authentication errors
            if let jellyfinError = error as? JellyfinError {
                switch jellyfinError {
                case .unauthorized, .forbidden:
                    // Token is invalid/expired - redirect to login
                    logger.info("🔄 Session expired (\(jellyfinError.errorDescription ?? "authentication error")) - redirecting to login")
                    await handleInvalidSession()
                    return
                    
                default:
                    // Other Jellyfin errors - keep user authenticated for now
                    logger.warning("⚠️ Jellyfin error during session validation (keeping user authenticated): \(jellyfinError.localizedDescription)")
                    return
                }
            }
            
            // Handle network errors - don't log out, user might be offline
            if let urlError = error as? URLError {
                logger.warning("⚠️ Network error during session validation: \(urlError.localizedDescription)")
                // Keep user authenticated, they can try again when online
                return
            }
            
            // Handle other errors - keep user authenticated unless clearly auth-related
            let errorString = error.localizedDescription.lowercased()
            if errorString.contains("401") || errorString.contains("403") || 
               errorString.contains("unauthorized") || errorString.contains("forbidden") {
                logger.info("🔄 Session expired (authentication error detected) - redirecting to login")
                await handleInvalidSession()
            } else {
                // Other errors (network, server issues) - keep user authenticated
                logger.warning("⚠️ Session validation error (keeping user authenticated): \(error.localizedDescription)")
            }
        }
    }
    
    /// Handles invalid session by clearing credentials and showing login
    @MainActor
    private func handleInvalidSession() async {
        // Clear stored credentials
        KeychainService.shared.deleteAccessToken()
        KeychainService.shared.deleteUserID()
        
        // Update authentication state
        self.isAuthenticated = false
        self.currentUser = nil
        
        logger.info("🔑 Cleared expired credentials - user will see login screen")
    }

    /// Signs out and clears stored credentials
    func signOut() {
        // Stop playback before signing out
        PlayerManager.shared.pause()
        PlayerManager.shared.clearQueue()
        Task { @MainActor in
            LibrarySyncCoordinator.shared.stopEventMonitoring()
        }

        isAuthenticated = false
        currentUser = nil
        KeychainService.shared.deleteAccessToken()
        KeychainService.shared.deleteUserID()
    }

    // MARK: - Public Computed Properties

    /// Current Jellyfin user ID from Keychain.
    var currentUserId: String? {
        KeychainService.shared.getUserID()
    }

    /// Image types worth requesting for an artist. Backdrop is wide by design
    /// and suits a header; Primary is a portrait and only looks right in a
    /// square. Thumb is deliberately absent — Jellyfin serves none for artists
    /// in practice, so asking for it only buys a 404 before the fallback.
    enum ArtistImageKind {
        case backdrop
        case primary

        var path: String {
            switch self {
            case .backdrop: return "Backdrop/0"
            case .primary: return "Primary"
            }
        }
    }

    /// Builds an artist image URL without needing the item's image tag. The tag
    /// is only a cache key, so omitting it costs nothing here and saves storing
    /// per-image tags in the local catalog. A kind the artist has no image for
    /// simply 404s, which the caller treats as "try the next candidate".
    func artistImageURL(
        artistID: String,
        kind: ArtistImageKind,
        maxWidth: Int
    ) -> URL? {
        guard !baseURL.isEmpty, !artistID.isEmpty else { return nil }
        return URL(string: "\(baseURL)/Items/\(artistID)/Images/\(kind.path)?maxWidth=\(maxWidth)")
    }

    var libraryScope: LibraryScope? {
        LibraryScope(baseURL: baseURL, userID: currentUserId)
    }

    /// Access token from Keychain
    var authToken: String? {
        KeychainService.shared.getAccessToken()
    }

    /// Get image URL for an item
    func getImageURL(itemId: String, imageTag: String, maxWidth: Int = 300, maxHeight: Int = 300) -> URL? {
        let urlString = "\(baseURL)/Items/\(itemId)/Images/Primary?maxWidth=\(maxWidth)&maxHeight=\(maxHeight)&tag=\(imageTag)&quality=90"
        return URL(string: urlString)
    }
}

// MARK: - Error Types

enum JellyfinError: LocalizedError {
    case notAuthenticated
    case invalidResponse
    case networkError(Error)
    case quickConnectTimeout
    case invalidURL
    case unauthorized
    case forbidden
    case notFound
    case httpError(statusCode: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not authenticated. Please sign in."
        case .invalidResponse:
            return "Invalid response from server."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .quickConnectTimeout:
            return "Quick Connect timed out. Please try again."
        case .invalidURL:
            return "Invalid server URL. Please check your server address."
        case .unauthorized:
            return "Session expired. Please sign in again."
        case .forbidden:
            return "Access forbidden. Please check your permissions."
        case .notFound:
            return "The requested Jellyfin feature is not installed."
        case .httpError(let statusCode, let message):
            if let message {
                return "Server returned HTTP \(statusCode): \(message)"
            }
            return "Server returned HTTP \(statusCode)."
        }
    }
}

// MARK: - Response Models

struct ItemsResponse: Codable {
    let Items: [BaseItemDto]
    let TotalRecordCount: Int

    // Custom decoder to skip bad items
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        TotalRecordCount = (try? container.decode(Int.self, forKey: .TotalRecordCount)) ?? 0

        // Decode items array manually to skip bad items
        if let itemsArray = try? container.decode([BaseItemDto].self, forKey: .Items) {
            Items = itemsArray
        } else {
            // If normal decode fails, try decoding one by one
            let itemsArrayContainer = try? container.nestedUnkeyedContainer(forKey: .Items)
            var validItems: [BaseItemDto] = []

            if var itemsArrayContainer = itemsArrayContainer {
                while !itemsArrayContainer.isAtEnd {
                    if let item = try? itemsArrayContainer.decode(BaseItemDto.self) {
                        validItems.append(item)
                    } else {
                        // Skip this bad item
                        _ = try? itemsArrayContainer.decode(AnyCodable.self)
                    }
                }
            }

            Items = validItems
        }
    }

    private enum CodingKeys: String, CodingKey {
        case Items, TotalRecordCount
    }
}

// Helper to decode and skip any value
private struct AnyCodable: Codable {
    let value: Any?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) {
            value = int
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict
        } else {
            value = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        // Not needed
    }
}
