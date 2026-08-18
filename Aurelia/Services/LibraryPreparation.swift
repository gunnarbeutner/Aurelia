//
//  LibraryPreparation.swift
//  Aurelia
//
//  Whether Discover currently owns the whole screen.
//
//  Preparation spans two phases with different signals behind them — the first
//  sync, then the refresh that promotion triggers — and the chrome around
//  Discover has to stay out of the way for both. Only Discover can tell where
//  it is in that sequence, so it publishes the answer here.
//

import Foundation
import Combine

@MainActor
final class LibraryPreparation: ObservableObject {
    static let shared = LibraryPreparation()

    @Published var isActive = false
}

/// How the preparation bar moves while nothing behind it is counting.
///
/// It eases towards the far end and never arrives, slowing as it closes: still
/// moving, never claiming the wait is over. Reaching full while the screen is
/// still up would say the wait is finished when it is not.
nonisolated enum PreparationCrawl {
    /// Short of full, so the bar cannot finish ahead of the work.
    static let ceiling = 0.97

    static let stepNanoseconds: UInt64 = 900_000_000

    /// The share of what is left that each step covers. Small enough that the
    /// bar keeps creeping for the minutes a large library can take.
    private static let fraction = 0.02

    static func step(from shown: Double) -> Double {
        guard shown < ceiling else { return shown }
        return shown + (ceiling - shown) * fraction
    }
}
