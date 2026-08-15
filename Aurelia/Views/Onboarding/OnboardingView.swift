//
//  OnboardingView.swift
//  Aurelia
//
//  Onboarding flow coordinator
//
//  The flow asks who you are, not how you would like to prove it. Quick
//  Connect is offered alongside that question rather than ahead of it: on a
//  phone with password autofill it is the slower path, and on a server that has
//  it switched off, presenting it at all was only ever a disappointment.
//

import SwiftUI

struct OnboardingView: View {
    @ObservedObject var jellyfinService = JellyfinService.shared
    @State private var currentStep: OnboardingStep = .serverSetup
    /// Chosen on the account picker, so the password screen can skip asking
    /// for something the server already told us.
    @State private var selectedUsername: String?
    /// False until the server says otherwise, so an unsupported server simply
    /// never mentions Quick Connect.
    @State private var isQuickConnectAvailable = false
    /// Whether the picker had anything to show. When it did not it forwards
    /// straight to the password form, and going back must not land on a screen
    /// that would immediately forward again.
    @State private var pickerHasUsers = false
    /// Where Quick Connect was entered from. Recorded rather than inferred:
    /// it is reachable from two screens, and working it out afterwards from
    /// the other state got it wrong for anyone who chose it on the picker.
    @State private var quickConnectOrigin: OnboardingStep = .userSelection

    enum OnboardingStep {
        case serverSetup
        case quickConnect
        case userSelection
        case passwordLogin
    }

    var body: some View {
        ZStack {
            switch currentStep {
            case .serverSetup:
                ServerSetupView {
                    // Both probes start together the moment the URL is good,
                    // so the picker has its answers by the time it appears.
                    checkQuickConnectAvailability()
                    withAnimation(.spring(response: 0.4)) {
                        currentStep = .userSelection
                    }
                }
                .transition(transition)

            case .userSelection:
                UserSelectionView(
                    isQuickConnectAvailable: isQuickConnectAvailable,
                    onSelect: { user in
                        selectedUsername = user.Name
                        pickerHasUsers = true
                        withAnimation(.spring(response: 0.4)) {
                            currentStep = .passwordLogin
                        }
                    },
                    onManualEntry: {
                        selectedUsername = nil
                        pickerHasUsers = true
                        withAnimation(.spring(response: 0.4)) {
                            currentStep = .passwordLogin
                        }
                    },
                    onNoUsers: {
                        selectedUsername = nil
                        pickerHasUsers = false
                        withAnimation(.spring(response: 0.4)) {
                            currentStep = .passwordLogin
                        }
                    },
                    onQuickConnect: {
                        quickConnectOrigin = .userSelection
                        withAnimation(.spring(response: 0.4)) {
                            currentStep = .quickConnect
                        }
                    },
                    onSuccess: {
                        // JellyfinService updates isAuthenticated
                    },
                    onBack: {
                        withAnimation(.spring(response: 0.4)) {
                            currentStep = .serverSetup
                        }
                    }
                )
                .transition(transition)

            case .passwordLogin:
                PasswordLoginView(
                    prefilledUsername: selectedUsername,
                    isQuickConnectAvailable: isQuickConnectAvailable,
                    onQuickConnect: {
                        quickConnectOrigin = .passwordLogin
                        withAnimation(.spring(response: 0.4)) {
                            currentStep = .quickConnect
                        }
                    },
                    onSuccess: {
                        // JellyfinService updates isAuthenticated
                    },
                    onBack: {
                        withAnimation(.spring(response: 0.4)) {
                            // Skip the picker when it had nothing to show, or
                            // it would forward straight back here.
                            currentStep = pickerHasUsers ? .userSelection : .serverSetup
                        }
                    }
                )
                .transition(transition)

            case .quickConnect:
                QuickConnectView {
                    // Success
                } onBack: {
                    withAnimation(.spring(response: 0.4)) {
                        currentStep = quickConnectOrigin
                    }
                }
                .transition(transition)
            }
        }
    }

    private var transition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }

    private func checkQuickConnectAvailability() {
        Task {
            // Unavailable is the safe answer: a server that cannot do this
            // should never be offered as though it could.
            isQuickConnectAvailable = (try? await jellyfinService.checkQuickConnect()) ?? false
        }
    }
}

#Preview {
    OnboardingView()
}
