//
//  UserSelectionView.swift
//  Aurelia
//
//  Pick an account from the ones the server advertises.
//
//  Jellyfin lets a server publish its users for exactly this screen. When it
//  does, typing a username is busywork the server can spare you. When it does
//  not — every user hidden, or an older server — this steps aside without
//  making the choice look like it failed.
//

import SwiftUI

struct UserSelectionView: View {
    @ObservedObject var jellyfinService = JellyfinService.shared

    @State private var users: [JellyfinService.PublicUser] = []
    @State private var isLoading = true
    @State private var signingInAs: String?
    @State private var errorMessage: String?

    /// Offered only when the server actually supports it.
    var isQuickConnectAvailable: Bool = false

    /// The chosen account still needs a password.
    let onSelect: (JellyfinService.PublicUser) -> Void
    /// The account wanted is not on the list.
    let onManualEntry: () -> Void
    /// The server published nothing, so there is no choice to present.
    let onNoUsers: () -> Void
    let onQuickConnect: () -> Void
    let onSuccess: () -> Void
    let onBack: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 20)]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.appBackground, Color.appMidBackground, Color.appBackground],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack {
                OnboardingBackButton(accessibilityLabel: "Go back to sign-in options") {
                    onBack()
                }

                Spacer()

                if isLoading {
                    ProgressView()
                        .tint(.appAccent)
                        .scaleEffect(1.4)
                } else {
                    content
                }

                Spacer()
            }
        }
        .task {
            await loadUsers()
        }
        .alert("Sign In Failed", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var content: some View {
        VStack(spacing: 32) {
            Image("AureliaLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 80, height: 80)
                .shadow(color: .appAccent.opacity(0.3), radius: 20, y: 0)

            VStack(spacing: 12) {
                Text("Who's Listening?")
                    .font(.title2.weight(.bold))
                    .foregroundColor(Color.appText)

                Text("Choose your account on this server")
                    .font(.body)
                    .foregroundColor(.secondary)
            }

            ScrollView {
                LazyVGrid(columns: columns, spacing: 24) {
                    ForEach(users) { user in
                        userButton(for: user)
                    }
                }
                .padding(.horizontal, 24)
                // Keeps the first and last rows off the clip boundary, so
                // nothing is trimmed at the edges of the scrolling area.
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 360)
            // A handful of accounts fits without scrolling; only a long list
            // should move.
            .scrollBounceBehavior(.basedOnSize)

            // Two tertiary actions in a row: spaced so neither is caught by a
            // thumb aimed at the other, and each given a full-height target
            // rather than only the few points its text occupies.
            VStack(spacing: 8) {
                Button(action: onManualEntry) {
                    Text("Use a different account")
                        .font(.appBody)
                        .foregroundColor(.appAccent)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("onboarding-manual-entry")

                // Identity is the question this screen asks, and Quick Connect
                // answers it on another device — so it belongs beside the grid
                // rather than inside it, and only when the server offers it.
                if isQuickConnectAvailable {
                    Button(action: onQuickConnect) {
                        Label("Sign in with a code instead", systemImage: "qrcode")
                            .font(.appCaption)
                            .foregroundColor(.appTextSecondary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("onboarding-quick-connect")
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private func userButton(for user: JellyfinService.PublicUser) -> some View {
        Button {
            select(user)
        } label: {
            VStack(spacing: 10) {
                ZStack {
                    avatar(for: user)

                    if signingInAs == user.Id {
                        Circle()
                            .fill(Color.black.opacity(0.45))
                        ProgressView()
                            .tint(.white)
                    }
                }
                .frame(width: 84, height: 84)
                .clipShape(Circle())
                .overlay(
                    // strokeBorder draws inside the shape. A plain stroke is
                    // centred on the path, putting half its width outside the
                    // frame — which the scroll view's clip rect then shaves off
                    // the top row.
                    Circle().strokeBorder(Color.appAccent.opacity(0.4), lineWidth: 1)
                )

                Text(user.Name)
                    .font(.appBody)
                    .foregroundColor(Color.appText)
                    .lineLimit(1)

                // Says why this account will not ask for a password, rather
                // than letting it look like the screen skipped a step.
                if !user.requiresPassword {
                    Text("No password")
                        .font(.appCaption)
                        .foregroundColor(.appTextMuted)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(signingInAs != nil)
        .accessibilityIdentifier("onboarding-user-\(user.Id)")
        .accessibilityLabel("Sign in as \(user.Name)")
    }

    @ViewBuilder
    private func avatar(for user: JellyfinService.PublicUser) -> some View {
        if let tag = user.PrimaryImageTag,
           let url = jellyfinService.userImageURL(userId: user.Id, imageTag: tag) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                default:
                    initialsAvatar(for: user)
                }
            }
        } else {
            initialsAvatar(for: user)
        }
    }

    private func initialsAvatar(for user: JellyfinService.PublicUser) -> some View {
        ZStack {
            LinearGradient(
                colors: [Color.appAccent.opacity(0.35), Color.appSecondary.opacity(0.35)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Text(initials(of: user.Name))
                .font(.title2.weight(.bold))
                .foregroundColor(Color.appText)
        }
    }

    private func initials(of name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    private func loadUsers() async {
        let published = await jellyfinService.fetchPublicUsers()
        users = published
        isLoading = false

        // Nothing to choose between, so do not make the user look at an empty
        // screen and work out that they were meant to press something else.
        if published.isEmpty {
            onNoUsers()
        }
    }

    private func select(_ user: JellyfinService.PublicUser) {
        guard user.requiresPassword == false else {
            onSelect(user)
            return
        }

        // A passwordless account has nothing left to ask for.
        signingInAs = user.Id
        Task {
            do {
                try await jellyfinService.authenticateByName(username: user.Name, password: "")
                onSuccess()
            } catch {
                signingInAs = nil
                // The server may want a password after all — send them to the
                // form rather than stranding them on an error.
                errorMessage = "\(user.Name) needs a password."
                onSelect(user)
            }
        }
    }
}

#Preview {
    UserSelectionView(
        isQuickConnectAvailable: true,
        onSelect: { _ in },
        onManualEntry: {},
        onNoUsers: {},
        onQuickConnect: {},
        onSuccess: {},
        onBack: {}
    )
}
