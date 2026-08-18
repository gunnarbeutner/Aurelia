//
//  PreparationCrawlTests.swift
//  AureliaTests
//
//  How the preparation bar behaves when nothing is measuring it.
//
//  The sync's own figure stops at its ceiling while the server materializes a
//  snapshot, which on a large library is minutes of the bar holding still. It
//  read as a stall, so the bar creeps instead — and these cover the two things
//  that creep must never do: stop, or arrive.
//

import Foundation
import Testing

@testable import Aurelia

@Suite struct PreparationCrawlTests {
    @Test func everyStepMovesTheBarForward() {
        var shown = 0.828
        for _ in 0..<50 {
            let next = PreparationCrawl.step(from: shown)
            #expect(next > shown)
            shown = next
        }
    }

    @Test func theBarNeverReachesTheCeiling() {
        var shown = 0.5
        for _ in 0..<10_000 {
            shown = PreparationCrawl.step(from: shown)
        }
        #expect(shown < PreparationCrawl.ceiling)
    }

    /// A wait that runs long should visibly slow rather than march at a rate
    /// that implies the end is near.
    @Test func stepsShrinkAsTheBarCloses() {
        let early = PreparationCrawl.step(from: 0.3) - 0.3
        let late = PreparationCrawl.step(from: 0.9) - 0.9
        #expect(late < early)
    }

    @Test func aBarAlreadyPastTheCeilingStaysPut() {
        #expect(PreparationCrawl.step(from: 0.99) == 0.99)
    }

    /// The first stretch of a long materialization wait has to be visible, or
    /// the creep says no more than holding still would.
    @Test func theCrawlIsVisibleWithinAMinute() {
        var shown = 0.828
        let stepsPerMinute = Int(60.0 / (Double(PreparationCrawl.stepNanoseconds) / 1_000_000_000))
        for _ in 0..<stepsPerMinute {
            shown = PreparationCrawl.step(from: shown)
        }
        #expect(shown - 0.828 > 0.05)
    }
}
