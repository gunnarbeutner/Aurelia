//
//  PublicUserTests.swift
//  AureliaTests
//
//  The account picker is driven entirely by what /Users/Public returns, and
//  servers vary in what they put there.
//

import Testing
import Foundation
@testable import Aurelia

struct PublicUserTests {

    @Test func decodesTheUsersAServerPublishes() throws {
        let payload = """
        [
          {"Name":"Gunnar","Id":"abc123","PrimaryImageTag":"tag1","HasPassword":true,
           "ServerId":"s1","HasConfiguredPassword":true},
          {"Name":"Guest","Id":"def456","HasPassword":false}
        ]
        """

        let users = try JSONDecoder().decode([JellyfinService.PublicUser].self, from: Data(payload.utf8))

        #expect(users.count == 2)
        #expect(users[0].Name == "Gunnar")
        #expect(users[0].id == "abc123")
        #expect(users[0].PrimaryImageTag == "tag1")
        #expect(users[0].requiresPassword)

        // No avatar and no password is a perfectly ordinary account.
        #expect(users[1].PrimaryImageTag == nil)
        #expect(!users[1].requiresPassword)
    }

    @Test func aMissingPasswordFlagIsTreatedAsNeedingOne() throws {
        // Older servers omit HasPassword entirely. Guessing "no password" would
        // walk the user into a sign-in that fails for no visible reason.
        let payload = """
        [{"Name":"Legacy","Id":"xyz"}]
        """

        let users = try JSONDecoder().decode([JellyfinService.PublicUser].self, from: Data(payload.utf8))

        #expect(users.count == 1)
        #expect(users[0].requiresPassword)
    }

    @Test func anEmptyListDecodesRatherThanFailing() throws {
        // Every user hidden from the login screen is a legitimate answer, and
        // means "make them type it" rather than "something went wrong".
        let users = try JSONDecoder().decode([JellyfinService.PublicUser].self, from: Data("[]".utf8))
        #expect(users.isEmpty)
    }

    @Test func unknownFieldsDoNotBreakDecoding() throws {
        // Jellyfin's UserDto is large and grows; the picker needs four fields.
        let payload = """
        [{"Name":"Gunnar","Id":"abc","HasPassword":true,
          "Policy":{"IsAdministrator":true},"Configuration":{"PlayDefaultAudioTrack":true},
          "LastLoginDate":"2026-08-15T10:00:00.0000000Z","SomethingNew":42}]
        """

        let users = try JSONDecoder().decode([JellyfinService.PublicUser].self, from: Data(payload.utf8))
        #expect(users.first?.Name == "Gunnar")
    }
}
