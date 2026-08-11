//
//  PasswordLoginView.swift
//  Aurelia
//
//  Username/password authentication screen
//

import SwiftUI

struct PasswordLoginView: View {
    @ObservedObject var jellyfinService = JellyfinService.shared
    @State private var username = ""
    @State private var password = ""
    @State private var isAuthenticating = false
    @State private var errorMessage = ""
    @State private var showError = false
    @FocusState private var focusedField: Field?

    enum Field {
        case username, password
    }

    let onSuccess: () -> Void
    let onBack: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.appBackground,
                    Color.appMidBackground,
                    Color.appBackground
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack {
                // Back button
                HStack {
                    Button {
                        onBack()
                    } label: {
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
                    .accessibilityLabel("Go back")
                    .padding(.leading, 20)
                    .padding(.top, 60)
                    Spacer()
                }

                ScrollView {
                    VStack(spacing: 0) {
                        Spacer()
                            .frame(height: 40)

                        // Logo
                        Image("AureliaLogo")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 80, height: 80)
                            .shadow(color: .appAccent.opacity(0.3), radius: 20, y: 0)
                            .padding(.bottom, 30)

                        // Title
                        VStack(spacing: 12) {
                            Text("Sign In")
                                .font(.title2.weight(.bold))
                                .foregroundColor(Color.appText)

                            Text("Enter your Jellyfin credentials")
                                .font(.body)
                                .foregroundColor(.secondary)
                        }
                        .padding(.bottom, 40)

                        // Form fields
                        VStack(spacing: 20) {
                            // Username
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Username")
                                    .font(.caption)
                                    .foregroundColor(.neonCyan)
                                    .textCase(.uppercase)
                                    .fontWeight(.semibold)

                                HStack(spacing: 12) {
                                    Image(systemName: "person.fill")
                                        .foregroundColor(.neonCyan)

                                    TextField("Username", text: $username)
                                        .foregroundColor(Color.appText)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                        .tint(.appAccent)
                                        .focused($focusedField, equals: .username)
                                        .submitLabel(.next)
                                        .onSubmit { focusedField = .password }
                                        .accessibilityLabel("Username")

                                    if !username.isEmpty {
                                        Button { username = "" } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundColor(.secondary)
                                        }
                                        .accessibilityLabel("Clear username")
                                    }
                                }
                                .padding(16)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.white.opacity(0.1))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12)
                                                .stroke(Color.appAccent.opacity(0.3), lineWidth: 1)
                                        )
                                )
                            }

                            // Password
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Password")
                                    .font(.caption)
                                    .foregroundColor(.neonCyan)
                                    .textCase(.uppercase)
                                    .fontWeight(.semibold)

                                HStack(spacing: 12) {
                                    Image(systemName: "lock.fill")
                                        .foregroundColor(.neonCyan)

                                    SecureField("Password", text: $password)
                                        .foregroundColor(Color.appText)
                                        .tint(.appAccent)
                                        .focused($focusedField, equals: .password)
                                        .submitLabel(.go)
                                        .onSubmit { signIn() }
                                        .accessibilityLabel("Password")

                                    if !password.isEmpty {
                                        Button { password = "" } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundColor(.secondary)
                                        }
                                        .accessibilityLabel("Clear password")
                                    }
                                }
                                .padding(16)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.white.opacity(0.1))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12)
                                                .stroke(Color.appAccent.opacity(0.3), lineWidth: 1)
                                        )
                                )
                            }
                        }
                        .padding(.horizontal, 30)
                        .padding(.bottom, 30)

                        // Sign In button
                        Button(action: signIn) {
                            HStack(spacing: 12) {
                                if isAuthenticating {
                                    ProgressView()
                                        .tint(.black)
                                } else {
                                    Image(systemName: "arrow.right")
                                        .font(.title3)
                                }

                                Text(isAuthenticating ? "Signing In..." : "Sign In")
                                    .font(.body.weight(.semibold))
                            }
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(canSignIn ? Color.appAccent : Color.gray)
                            )
                        }
                        .disabled(!canSignIn || isAuthenticating)
                        .padding(.horizontal, 30)
                        .padding(.bottom, 20)
                        .accessibilityLabel(isAuthenticating ? "Signing in" : "Sign in")

                        // Help text
                        HStack(spacing: 12) {
                            Image(systemName: "info.circle")
                                .foregroundColor(.neonPink.opacity(0.8))
                                .font(.caption)

                            Text("Use your Jellyfin username and password to sign in")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.white.opacity(0.05))
                        )
                        .padding(.horizontal, 30)

                        Spacer()
                    }
                }
            }
        }
        .alert("Login Error", isPresented: $showError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
        .onAppear {
            focusedField = .username
        }
    }

    private var canSignIn: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func signIn() {
        guard canSignIn else { return }
        isAuthenticating = true
        focusedField = nil

        Task {
            do {
                try await jellyfinService.authenticateByName(
                    username: username.trimmingCharacters(in: .whitespaces),
                    password: password
                )
                await MainActor.run {
                    onSuccess()
                }
            } catch {
                await MainActor.run {
                    isAuthenticating = false
                    if case JellyfinError.unauthorized = error {
                        errorMessage = "Invalid username or password. Please try again."
                    } else if error is KeychainServiceError {
                        errorMessage = error.localizedDescription
                    } else {
                        let endpoint = jellyfinService.baseURL.isEmpty ? "the Jellyfin server" : jellyfinService.baseURL
                        errorMessage = "Sign in to \(endpoint) failed.\n\n\(error.localizedDescription)"
                    }
                    showError = true
                }
            }
        }
    }
}

#Preview {
    PasswordLoginView(onSuccess: {}, onBack: {})
}
