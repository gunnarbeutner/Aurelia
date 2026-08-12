//
//  WatchOnboardingView.swift
//  Aurelia Watch
//
//  Onboarding view for Apple Watch when no credentials are available
//

import SwiftUI

struct WatchOnboardingView: View {
    @ObservedObject private var connectivity = WatchConnectivityManager.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image("AppIcon_Display")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityHidden(true)

                Text("Sign In Required")
                    .font(.headline)
                    .multilineTextAlignment(.center)

                Text("Open Aurelia on your iPhone, then sync again.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Sync Again") {
                    connectivity.requestCredentials()
                    connectivity.requestLibrarySnapshot()
                }
                .buttonStyle(.bordered)
                .disabled(!connectivity.isPhoneReachable)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .containerBackground(.black.gradient, for: .navigation)
    }
}

#Preview {
    WatchOnboardingView()
}
