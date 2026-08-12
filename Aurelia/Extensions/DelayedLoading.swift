//
//  DelayedLoading.swift
//  Aurelia
//
//  Defers loading indicators so local reads do not flash a spinner
//

import Foundation

/// Runs work while holding a loading indicator back until the work outlasts a
/// short threshold.
///
/// Library reads come from SQLite now, but `LibraryRepository` is an actor, so
/// even an instant query costs a hop off the main actor and back. A view that
/// starts in a loading state therefore renders at least one frame of spinner
/// for a round trip that never leaves the device. Waiting a beat before showing
/// the indicator keeps that case silent while still explaining a genuinely slow
/// query.
@MainActor
enum DelayedLoading {
    /// Below roughly this long a transition reads as instant, so showing an
    /// indicator only makes the UI feel busier than it is.
    static let threshold: Duration = .milliseconds(150)

    static func run(
        showIndicator: @escaping @MainActor (Bool) -> Void,
        work: () async -> Void
    ) async {
        let indicator = Task { @MainActor in
            try? await Task.sleep(for: threshold)
            guard !Task.isCancelled else { return }
            showIndicator(true)
        }

        await work()

        indicator.cancel()
        showIndicator(false)
    }
}
