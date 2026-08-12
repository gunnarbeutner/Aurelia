//
//  OnboardingBackButton.swift
//  Aurelia
//
//  The single back control shared by every onboarding screen
//

import SwiftUI

/// Back button for the onboarding flow, including its leading alignment.
///
/// The three onboarding screens previously each drew their own, which is how
/// they drifted apart in both position and appearance. Keeping one definition
/// means fixing it once fixes it everywhere.
struct OnboardingBackButton: View {
    var accessibilityLabel: String = "Go back"
    let action: () -> Void

    var body: some View {
        HStack {
            Button(action: action) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                    Text("Back")
                }
                .font(.body)
                .foregroundColor(Color.appText)
                .padding(12)
                .background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                )
            }
            .accessibilityLabel(accessibilityLabel)
            .padding(.leading, 20)
            .padding(.top, 8)

            Spacer()
        }
    }
}
