//
//  OnboardingView.swift
//  Aurelia
//
//  Onboarding flow coordinator
//

import SwiftUI

struct OnboardingView: View {
    @ObservedObject var jellyfinService = JellyfinService.shared
    @State private var currentStep: OnboardingStep = .serverSetup
    /// Chosen on the account picker, so the password screen can skip asking
    /// for something the server already told us.
    @State private var selectedUsername: String?

    enum OnboardingStep {
        case serverSetup
        case authChoice
        case quickConnect
        case userSelection
        case passwordLogin
    }

    var body: some View {
        ZStack {
            switch currentStep {
            case .serverSetup:
                ServerSetupView {
                    withAnimation(.spring(response: 0.4)) {
                        currentStep = .authChoice
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))

            case .authChoice:
                AuthChoiceView(
                    onQuickConnect: {
                        withAnimation(.spring(response: 0.4)) {
                            currentStep = .quickConnect
                        }
                    },
                    onPasswordLogin: {
                        selectedUsername = nil
                        withAnimation(.spring(response: 0.4)) {
                            // The picker decides for itself whether it has
                            // anything to show, and steps aside if not.
                            currentStep = .userSelection
                        }
                    },
                    onBack: {
                        withAnimation(.spring(response: 0.4)) {
                            currentStep = .serverSetup
                        }
                    }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))

            case .quickConnect:
                QuickConnectView {
                    // Success
                } onBack: {
                    withAnimation(.spring(response: 0.4)) {
                        currentStep = .authChoice
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))

            case .userSelection:
                UserSelectionView(
                    onSelect: { user in
                        selectedUsername = user.Name
                        withAnimation(.spring(response: 0.4)) {
                            currentStep = .passwordLogin
                        }
                    },
                    onManualEntry: {
                        selectedUsername = nil
                        withAnimation(.spring(response: 0.4)) {
                            currentStep = .passwordLogin
                        }
                    },
                    onSuccess: {
                        // JellyfinService updates isAuthenticated
                    },
                    onBack: {
                        withAnimation(.spring(response: 0.4)) {
                            currentStep = .authChoice
                        }
                    }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))

            case .passwordLogin:
                PasswordLoginView(prefilledUsername: selectedUsername) {
                    // Success — JellyfinService updates isAuthenticated
                } onBack: {
                    withAnimation(.spring(response: 0.4)) {
                        // Back belongs to wherever this was reached from.
                        currentStep = selectedUsername == nil ? .authChoice : .userSelection
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
            }
        }
    }
}

#Preview {
    OnboardingView()
}
