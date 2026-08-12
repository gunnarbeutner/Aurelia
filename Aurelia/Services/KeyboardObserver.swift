//
//  KeyboardObserver.swift
//  Aurelia
//
//  Whether the software keyboard is on screen.
//

import Combine
import UIKit

/// Typing hides the mini player and, with it, the space reserved for the mini
/// player further down the view tree. Those two live in different views, so the
/// signal is shared rather than tracked twice and left to drift apart.
final class KeyboardObserver: ObservableObject {
    static let shared = KeyboardObserver()

    @Published private(set) var isVisible = false

    private var cancellables: Set<AnyCancellable> = []
    private var isStarted = false

    func start() {
        guard !isStarted else { return }
        isStarted = true

        // `will` rather than `did`, so the mini player is gone as the keyboard
        // starts moving instead of after it has arrived.
        NotificationCenter.default
            .publisher(for: UIResponder.keyboardWillShowNotification)
            .sink { [weak self] _ in self?.isVisible = true }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: UIResponder.keyboardWillHideNotification)
            .sink { [weak self] _ in self?.isVisible = false }
            .store(in: &cancellables)
    }
}
