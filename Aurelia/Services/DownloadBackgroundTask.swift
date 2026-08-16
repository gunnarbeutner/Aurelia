//
//  DownloadBackgroundTask.swift
//  Aurelia
//
//  Keeps a long download run moving while nobody is holding the phone.
//
//  A background URLSession works through whatever it has been given, but it
//  cannot ask for more, and the app is only woken to be told a transfer
//  finished — seconds of runtime, enough to hand over one more batch. On a
//  library-sized run that is a batch every twenty minutes or worse, so a phone
//  left alone overnight barely moves.
//
//  This asks the system for real runtime instead. It is granted when the device
//  is idle and usually charging, which is exactly when a large sync should
//  happen, and each run books the next one before it ends.
//

import BackgroundTasks
import Foundation
import os.log

enum DownloadBackgroundTask {
    static let identifier = "de.beutner.Aurelia.favoritesSync"

    private static let logger = Logger(subsystem: "de.beutner.Aurelia", category: "DownloadTask")

    /// Submitting replaces whatever is already booked, so re-booking on every
    /// finished download would be several hundred pointless submissions during
    /// a large run. Once a minute is plenty to keep one on the books.
    private static let rebookInterval: TimeInterval = 60
    nonisolated(unsafe) private static var lastBooked = Date.distantPast

    /// Must be called before the app finishes launching, or the system refuses
    /// to hand the task over later.
    static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: nil
        ) { task in
            guard let task = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(task)
        }
    }

    /// Books a run, if there is anything left to download.
    ///
    /// Submitting replaces any request already queued, so this is safe to call
    /// whenever the queue changes.
    static func schedule(force: Bool = false) {
        Task { @MainActor in
            guard DownloadManager.shared.hasPendingWork else {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
                lastBooked = .distantPast
                return
            }

            guard force || Date().timeIntervalSince(lastBooked) >= rebookInterval else { return }
            lastBooked = Date()

            let request = BGProcessingTaskRequest(identifier: identifier)
            request.requiresNetworkConnectivity = true
            // Not required, because a phone that is simply set down should still
            // make progress. The system already prefers to run these on power.
            request.requiresExternalPower = false

            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                logger.error("Could not schedule the download task: \(error.localizedDescription)")
            }
        }
    }

    private static func handle(_ task: BGProcessingTask) {
        // The next run is booked first: if this one is cut short there is still
        // one on the books, and a run that ends without booking another is the
        // end of the sync.
        schedule(force: true)

        let work = Task { @MainActor in
            DownloadManager.shared.resumePendingWork()

            // Held open while transfers are in flight, so the session is topped
            // back up as they land rather than only at the start.
            while !Task.isCancelled, DownloadManager.shared.hasPendingWork {
                try? await Task.sleep(for: .seconds(5))
                DownloadManager.shared.resumePendingWork()
            }
        }

        task.expirationHandler = {
            work.cancel()
        }

        Task {
            _ = await work.result
            logger.info("Background download run finished")
            task.setTaskCompleted(success: true)
        }
    }
}
