//
//  KeychainService.swift
//  Aurelia
//
//  Secure storage for the Jellyfin server and authenticated session.
//

import Foundation
import Security

enum KeychainServiceError: LocalizedError {
    case operationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .operationFailed(let status) where status == errSecMissingEntitlement:
            return "Aurelia could not securely save your login because this build is not signed for Keychain access. In Xcode, enable Automatic Signing for the Aurelia target and run the Aurelia macOS scheme again."
        case .operationFailed(let status):
            let systemMessage = SecCopyErrorMessageString(status, nil) as String?
            return systemMessage.map { "Aurelia could not securely save your login: \($0) (\(status))." }
                ?? "Aurelia could not securely save your login (Keychain error \(status))."
        }
    }
}

/// Service for secure storage of the Jellyfin account in Keychain.
/// Provides thread-safe access to encrypted credential storage
class KeychainService {
    static let shared = KeychainService()

    private let serviceName = "de.beutner.Aurelia.jellyfin"
    private let accountName = "jellyfinAccessToken"
    private let serverURLName = "jellyfinServerURL"
    private let userIDName = "jellyfinUserId"
    private let aureliaSyncClientIDName = "aureliaSyncClientId"

    private init() {}

    // MARK: - Public Methods

    /// Saves access token to Keychain
    /// - Parameter token: The Jellyfin access token to store securely
    func saveAccessToken(_ token: String) throws {
        try save(token, account: accountName)
    }

    /// Retrieves access token from Keychain
    /// - Returns: The stored Jellyfin access token, or nil if not found
    func getAccessToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)

        if status == errSecSuccess,
           let data = dataTypeRef as? Data,
           let token = String(data: data, encoding: .utf8) {
            return token
        }

        return nil
    }

    /// Deletes access token from Keychain
    /// Used during sign out to ensure complete credential removal
    func deleteAccessToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountName
        ]

        let status = SecItemDelete(query as CFDictionary)

        if status != errSecSuccess && status != errSecItemNotFound {
            print("Failed to delete access token from Keychain: \(status)")
        }
    }

    func saveServerURL(_ serverURL: String) throws {
        try save(serverURL, account: serverURLName)
    }

    func getServerURL() -> String? {
        value(account: serverURLName)
    }

    func saveUserID(_ userID: String) throws {
        try save(userID, account: userIDName)
    }

    func getUserID() -> String? {
        value(account: userIDName)
    }

    func deleteUserID() {
        remove(for: userIDName)
    }

    /// Stable identity of this Aurelia installation in AureliaSync. Unlike the
    /// Jellyfin playback device ID this lives in Keychain, so reinstalling the
    /// app resumes the same server-side checkpoint instead of creating a new
    /// subscription and downloading another snapshot.
    func aureliaSyncClientID() throws -> String {
        if let existing = value(account: aureliaSyncClientIDName),
           UUID(uuidString: existing) != nil {
            return existing
        }
        let clientID = UUID().uuidString.lowercased()
        try save(clientID, account: aureliaSyncClientIDName)
        return clientID
    }

    // MARK: - Additional Secure Storage

    /// Generic method to store any sensitive string data
    /// - Parameters:
    ///   - value: The string value to store
    ///   - key: The unique key for this value
    func store(_ value: String, for key: String) {
        let data = Data(value.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    /// Generic method to retrieve any stored string data
    /// - Parameter key: The unique key for the value
    /// - Returns: The stored string value, or nil if not found
    func retrieve(for key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)

        if status == errSecSuccess,
           let data = dataTypeRef as? Data,
           let value = String(data: data, encoding: .utf8) {
            return value
        }

        return nil
    }

    /// Removes a stored value
    /// - Parameter key: The unique key for the value to remove
    func remove(for key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]

        SecItemDelete(query as CFDictionary)
    }

    /// Clears all stored credentials
    /// Use with caution - this will remove all app keychain data
    func clearAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName
        ]

        SecItemDelete(query as CFDictionary)
    }

    private func save(_ value: String, account: String) throws {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        let data = Data(value.utf8)

        let updateStatus = SecItemUpdate(
            identity as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainServiceError.operationFailed(updateStatus)
        }

        var newItem = identity
        newItem[kSecValueData as String] = data
        // Available after first unlock for background playback and sync.
        newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(newItem as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainServiceError.operationFailed(status)
        }
    }

    private func value(account: String) -> String? {
        retrieve(for: account)
    }
}
