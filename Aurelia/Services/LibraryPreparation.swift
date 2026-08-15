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
