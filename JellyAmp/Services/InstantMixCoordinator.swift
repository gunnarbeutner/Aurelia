//
//  InstantMixCoordinator.swift
//  JellyAmp
//
//  Shared loading, cancellation, playback, and error state for Instant Mix.
//

import Foundation
import Combine

@MainActor
final class InstantMixCoordinator: ObservableObject {
    static let shared = InstantMixCoordinator()

    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let service: JellyfinService
    private let playerManager: PlayerManager
    private var requestTask: Task<Void, Never>?
    private var requestId: UUID?

    private init() {
        self.service = .shared
        self.playerManager = .shared
    }

    func play(itemId: String, itemName: String) {
        requestTask?.cancel()

        let id = UUID()
        requestId = id
        isLoading = true
        errorMessage = nil

        requestTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.requestId == id {
                    self.isLoading = false
                    self.requestTask = nil
                }
            }

            do {
                let items = try await self.service.fetchInstantMix(itemId: itemId, limit: 50)
                try Task.checkCancellation()
                guard self.requestId == id else { return }

                let tracks = items
                    .filter { $0.Type == .Audio }
                    .map { Track(from: $0, baseURL: self.service.baseURL) }
                guard !tracks.isEmpty else {
                    self.errorMessage = "No Instant Mix is available for \(itemName) yet."
                    return
                }

                self.playerManager.play(tracks: tracks)
                NavigationCoordinator.shared.presentNowPlaying()
            } catch is CancellationError {
                return
            } catch {
                guard self.requestId == id else { return }
                self.errorMessage = "Unable to create an Instant Mix for \(itemName): \(error.localizedDescription)"
            }
        }
    }
}
