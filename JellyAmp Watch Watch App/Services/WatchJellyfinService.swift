//
//  WatchJellyfinService.swift
//  JellyAmp Watch
//
//  Jellyfin API service for Apple Watch
//  Streams directly from Jellyfin server over cellular/WiFi
//

import Foundation
import Combine

class WatchJellyfinService: ObservableObject {
    static let shared = WatchJellyfinService()

    @Published var isAuthenticated = false
    @Published var baseURL = ""
    @Published var userName = ""

    private var accessToken: String?
    private var userId: String?
    var libraryScope: WatchLibraryScope? {
        WatchLibraryScope(baseURL: baseURL, userID: userId)
    }
    private static let deviceIdKey = "JellyAmpWatchDeviceId"
    let deviceId: String = {
        if let existing = UserDefaults.standard.string(forKey: deviceIdKey) {
            return existing
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: deviceIdKey)
        return newId
    }()

    init() {
        loadCredentials()
        
        // Validate session if credentials exist
        if isAuthenticated {
            Task {
                await validateSessionOnLaunch()
            }
        }
    }

    // MARK: - Authentication

    func setCredentials(baseURL: String, accessToken: String, userId: String, userName: String) {
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.userId = userId
        self.userName = userName

        // Save to UserDefaults (watch doesn't have shared keychain access)
        UserDefaults.standard.set(baseURL, forKey: "jellyfinBaseURL")
        UserDefaults.standard.set(accessToken, forKey: "jellyfinAccessToken")
        UserDefaults.standard.set(userId, forKey: "jellyfinUserId")
        UserDefaults.standard.set(userName, forKey: "jellyfinUserName")

        isAuthenticated = true

        Task { @MainActor in
            await WatchLibraryStore.shared.activate()
        }
    }

    func loadCredentials() {
        if let url = UserDefaults.standard.string(forKey: "jellyfinBaseURL"),
           let token = UserDefaults.standard.string(forKey: "jellyfinAccessToken"),
           let uid = UserDefaults.standard.string(forKey: "jellyfinUserId"),
           let name = UserDefaults.standard.string(forKey: "jellyfinUserName") {
            baseURL = url
            accessToken = token
            userId = uid
            userName = name
            isAuthenticated = true
        }
    }

    func signOut() {
        UserDefaults.standard.removeObject(forKey: "jellyfinBaseURL")
        UserDefaults.standard.removeObject(forKey: "jellyfinAccessToken")
        UserDefaults.standard.removeObject(forKey: "jellyfinUserId")
        UserDefaults.standard.removeObject(forKey: "jellyfinUserName")

        baseURL = ""
        accessToken = nil
        userId = nil
        userName = ""
        isAuthenticated = false
        WatchLibraryStore.shared.deactivate()
    }
    
    /// Validates current session by fetching user info
    func validateSession() async throws -> Bool {
        guard let token = accessToken, let userId = userId else { return false }
        
        let endpoint = "\(baseURL)/Users/Me"
        guard let url = URL(string: endpoint) else {
            throw NSError(domain: "WatchJellyfin", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }
        
        var request = URLRequest(url: url)
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("MediaBrowser Token=\"\(token)\"", forHTTPHeaderField: "Authorization")
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }
            
            switch httpResponse.statusCode {
            case 200:
                return true
            case 401, 403:
                throw NSError(domain: "WatchJellyfin", code: httpResponse.statusCode, userInfo: [
                    NSLocalizedDescriptionKey: "Session expired"
                ])
            default:
                return false
            }
        } catch {
            throw error
        }
    }
    
    /// Validates session on app launch and handles authentication state
    @MainActor
    private func validateSessionOnLaunch() async {
        guard accessToken != nil else {
            // No token - stay unauthenticated
            isAuthenticated = false
            return
        }
        
        do {
            let isValid = try await validateSession()
            if isValid {
                print("✅ Watch session validated successfully on app launch")
            }
        } catch {
            // Handle network errors vs authentication errors
            if let nsError = error as NSError? {
                let statusCode = nsError.code
                if statusCode == 401 || statusCode == 403 {
                    // Authentication failed - token is invalid/expired
                    print("🔄 Watch session expired (HTTP \(statusCode)) - clearing credentials")
                    await handleInvalidSession()
                    return
                }
            }
            
            // Handle network errors - don't log out, user might be offline
            if let urlError = error as? URLError {
                print("⚠️ Watch network error during session validation: \(urlError.localizedDescription)")
                // Keep user authenticated, they can try again when online
                return
            }
            
            // Check error description for auth-related keywords
            let errorString = error.localizedDescription.lowercased()
            if errorString.contains("401") || errorString.contains("403") || 
               errorString.contains("unauthorized") || errorString.contains("forbidden") {
                print("🔄 Watch session expired (authentication error detected) - clearing credentials")
                await handleInvalidSession()
            } else {
                // Other errors - keep user authenticated
                print("⚠️ Watch session validation error (keeping user authenticated): \(error.localizedDescription)")
            }
        }
    }
    
    /// Handles invalid session by clearing credentials
    @MainActor
    private func handleInvalidSession() async {
        // Clear stored credentials
        signOut()
        print("🔑 Watch cleared expired credentials - user needs to re-sync from phone")
    }

    // MARK: - Library Fetching

    func fetchCompleteLibrarySnapshot() async throws -> WatchLibraryTransferSnapshot {
        guard let userId = userId, let token = accessToken else {
            throw NSError(domain: "WatchJellyfin", code: 401, userInfo: [NSLocalizedDescriptionKey: "Not authenticated"])
        }
        guard let scope = libraryScope else {
            throw NSError(domain: "WatchJellyfin", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid library scope"])
        }

        let artistItems = try await fetchAllItems(
            endpoint: "\(baseURL)/Artists",
            params: [
            "UserId": userId,
            "Recursive": "true",
            "SortBy": "SortName",
            "SortOrder": "Ascending",
            "Fields": "BasicSyncInfo"
            ],
            token: token
        )
        let albumItems = try await fetchAllItems(
            endpoint: "\(baseURL)/Users/\(userId)/Items",
            params: [
            "IncludeItemTypes": "MusicAlbum",
            "Recursive": "true",
            "SortBy": "SortName",
            "SortOrder": "Ascending",
            "Fields": "BasicSyncInfo,PrimaryImageAspectRatio,ProductionYear,ArtistItems"
            ],
            token: token
        )
        let trackItems = try await fetchAllItems(
            endpoint: "\(baseURL)/Users/\(userId)/Items",
            params: [
            "IncludeItemTypes": "Audio",
            "Recursive": "true",
            "SortBy": "Album,SortName",
            "Fields": "AudioInfo,ParentId,AlbumId,ArtistItems,UserData,ProductionYear"
            ],
            token: token
        )

        return WatchLibraryTransferSnapshot(
            scope: scope,
            artists: artistItems.compactMap(WatchArtist.init(from:)),
            albums: albumItems.compactMap(WatchAlbum.init(from:)),
            tracks: trackItems.compactMap(WatchTrack.init(from:))
        )
    }

    // MARK: - Favorites

    /// Mark an item as favorite
    func markFavorite(itemId: String) async throws {
        guard let token = accessToken, let userId = userId else {
            throw NSError(domain: "WatchJellyfin", code: 401, userInfo: [NSLocalizedDescriptionKey: "Not authenticated"])
        }

        let endpoint = "\(baseURL)/Users/\(userId)/FavoriteItems/\(itemId)"
        guard let url = URL(string: endpoint) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("MediaBrowser Token=\"\(token)\"", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(domain: "WatchJellyfin", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to mark as favorite"])
        }
    }

    /// Remove item from favorites
    func unmarkFavorite(itemId: String) async throws {
        guard let token = accessToken, let userId = userId else {
            throw NSError(domain: "WatchJellyfin", code: 401, userInfo: [NSLocalizedDescriptionKey: "Not authenticated"])
        }

        let endpoint = "\(baseURL)/Users/\(userId)/FavoriteItems/\(itemId)"
        guard let url = URL(string: endpoint) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.addValue("MediaBrowser Token=\"\(token)\"", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(domain: "WatchJellyfin", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to remove from favorites"])
        }
    }

    // MARK: - Streaming URL

    func getStreamingURL(for trackId: String) -> URL? {
        guard let token = accessToken else { return nil }

        // Use /stream?static=true (direct file streaming) instead of /universal (transcoding)
        // The /universal endpoint causes playback restarts on cellular due to transcoding session resets
        // Static streaming is more reliable, especially on watchOS cellular connections
        let endpoint = "\(baseURL)/Audio/\(trackId)/stream"
        let params = [
            "static": "true",
            "mediaSourceId": trackId,
            "api_key": token
        ]

        return buildURL(endpoint: endpoint, params: params)
    }

    // MARK: - Helper

    private func buildURL(endpoint: String, params: [String: String]) -> URL {
        var components = URLComponents(string: endpoint)!
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }

    private func fetchAllItems(
        endpoint: String,
        params: [String: String],
        token: String
    ) async throws -> [ItemDto] {
        let pageSize = 500
        var startIndex = 0
        var items: [ItemDto] = []
        var seen = Set<String>()

        while true {
            var pageParams = params
            pageParams["Limit"] = String(pageSize)
            pageParams["StartIndex"] = String(startIndex)

            let url = buildURL(endpoint: endpoint, params: pageParams)
            var request = URLRequest(url: url)
            request.addValue("MediaBrowser Token=\"\(token)\"", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 500
                throw NSError(
                    domain: "WatchJellyfin",
                    code: status,
                    userInfo: [NSLocalizedDescriptionKey: "Library request failed (HTTP \(status))."]
                )
            }

            let page = try JSONDecoder().decode(ItemsResponse.self, from: data)
            for item in page.Items where seen.insert(item.Id).inserted {
                items.append(item)
            }
            startIndex += page.Items.count
            if page.Items.count < pageSize || startIndex >= (page.TotalRecordCount ?? .max) {
                break
            }
        }
        return items
    }
}

// MARK: - Response Models

struct ItemsResponse: Codable {
    let Items: [ItemDto]
    let TotalRecordCount: Int?
}

struct ItemDto: Codable {
    let Id: String
    let Name: String
    let `Type`: String?  // Escaped because Type is reserved keyword
    let RunTimeTicks: Int64?
    let AlbumArtist: String?
    let AlbumArtists: [NameIdPair]?
    let Artists: [String]?
    let Album: String?
    let ProductionYear: Int?
    let ParentId: String?  // Album ID for tracks
    let AlbumId: String?
    let ArtistItems: [NameIdPair]?
    let IndexNumber: Int?
    let ParentIndexNumber: Int?
    let UserData: UserDataDto?
}

struct UserDataDto: Codable {
    let IsFavorite: Bool?
}

struct NameIdPair: Codable {
    let Name: String
    let Id: String
}

// MARK: - Watch Models

nonisolated struct WatchArtist: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    init?(from dto: ItemDto) {
        guard dto.`Type` == "MusicArtist" else { return nil }
        self.id = dto.Id
        self.name = dto.Name
    }
}

nonisolated struct WatchAlbum: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let artist: String
    let artistId: String?
    let year: Int?

    init(id: String, name: String, artist: String, artistId: String?, year: Int?) {
        self.id = id
        self.name = name
        self.artist = artist
        self.artistId = artistId
        self.year = year
    }

    init?(from dto: ItemDto) {
        guard dto.`Type` == "MusicAlbum" else { return nil }
        self.id = dto.Id
        self.name = dto.Name
        self.artist = dto.AlbumArtist ?? dto.AlbumArtists?.first?.Name ?? "Unknown Artist"
        self.artistId = dto.AlbumArtists?.first?.Id ?? dto.ArtistItems?.first?.Id
        self.year = dto.ProductionYear
    }
}

nonisolated struct WatchTrack: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let artist: String
    let artistIds: [String]
    let album: String
    let albumId: String
    let duration: TimeInterval
    let indexNumber: Int?
    let parentIndexNumber: Int?
    var isFavorite: Bool

    init(
        id: String,
        name: String,
        artist: String,
        artistIds: [String],
        album: String,
        albumId: String,
        duration: TimeInterval,
        indexNumber: Int?,
        parentIndexNumber: Int?,
        isFavorite: Bool
    ) {
        self.id = id
        self.name = name
        self.artist = artist
        self.artistIds = artistIds
        self.album = album
        self.albumId = albumId
        self.duration = duration
        self.indexNumber = indexNumber
        self.parentIndexNumber = parentIndexNumber
        self.isFavorite = isFavorite
    }

    init?(from dto: ItemDto) {
        guard dto.`Type` == "Audio" else { return nil }
        self.id = dto.Id
        self.name = dto.Name
        self.artist = dto.Artists?.first ?? dto.AlbumArtist ?? "Unknown Artist"
        self.artistIds = dto.ArtistItems?.map(\.Id) ?? dto.AlbumArtists?.map(\.Id) ?? []
        self.album = dto.Album ?? ""
        self.albumId = dto.AlbumId ?? dto.ParentId ?? ""
        self.indexNumber = dto.IndexNumber
        self.parentIndexNumber = dto.ParentIndexNumber
        self.isFavorite = dto.UserData?.IsFavorite ?? false

        if let ticks = dto.RunTimeTicks {
            self.duration = Double(ticks) / 10_000_000.0
        } else {
            self.duration = 0
        }
    }
}
