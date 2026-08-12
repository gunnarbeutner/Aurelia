//
//  OfflineAvailabilityModifier.swift
//  Aurelia
//
//  Fades catalog entries that have nothing downloaded while the server is out
//  of reach, so it is obvious at a glance what will still play.
//

import SwiftUI

private struct OfflineAvailabilityModifier: ViewModifier {
    @ObservedObject private var availability = OfflineAvailability.shared
    let subject: OfflineSubject

    @ViewBuilder
    func body(content: Content) -> some View {
        if availability.isUnavailable(subject) {
            content
                .opacity(0.35)
                .saturation(0.2)
                // Dimming alone reads as "loading" to VoiceOver users, who get
                // none of it.
                .accessibilityHint("Not downloaded, unavailable offline")
        } else {
            content
        }
    }
}

extension View {
    func offlineAvailability(_ subject: OfflineSubject) -> some View {
        modifier(OfflineAvailabilityModifier(subject: subject))
    }
}
