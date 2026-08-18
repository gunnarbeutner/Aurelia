//
//  AureliaSyncPublicationRecoveryTests.swift
//  AureliaTests
//
//  Which checkpoints are worth throwing away.
//
//  Asking for a fresh snapshot costs the whole library, and asking for one
//  mid-snapshot costs it repeatedly: the reopen that follows a session bound
//  would discard the staged rows and start again, forever, on any library too
//  large to arrive in one session.
//

import Foundation
import Testing

@testable import Aurelia

@Suite struct AureliaSyncPublicationRecoveryTests {
    /// The case it exists for: a checkpoint from a build that predates the
    /// publication marker, with nothing staged behind it.
    @Test func aLegacyCheckpointIsReplaced() {
        #expect(AureliaSyncPublicationRecovery.isNeeded(
            checkpointToken: "token",
            snapshotGeneration: nil,
            publishedSnapshotGeneration: nil
        ))
    }

    /// The regression: a snapshot part-way through staging acknowledges as it
    /// goes, and publishes only at the end.
    @Test func anInterruptedSnapshotResumesInsteadOfRestarting() {
        #expect(!AureliaSyncPublicationRecovery.isNeeded(
            checkpointToken: "token",
            snapshotGeneration: "generation-1",
            publishedSnapshotGeneration: nil
        ))
    }

    @Test func aPublishedSnapshotIsLeftAlone() {
        #expect(!AureliaSyncPublicationRecovery.isNeeded(
            checkpointToken: "token",
            snapshotGeneration: "generation-1",
            publishedSnapshotGeneration: "generation-1"
        ))
    }

    /// A first sync has nothing to recover, and the server decides the mode.
    @Test func aClientWithNoCheckpointAsksForNothing() {
        #expect(!AureliaSyncPublicationRecovery.isNeeded(
            checkpointToken: nil,
            snapshotGeneration: nil,
            publishedSnapshotGeneration: nil
        ))
    }
}
