//
//  ServerSetupView.swift
//  Aurelia
//
//  Server URL setup screen for onboarding - iOS 26 Liquid Glass + Cypherpunk
//

import SwiftUI

struct ServerSetupView: View {
    @ObservedObject var jellyfinService = JellyfinService.shared
    @State private var serverURL = ""
    @State private var isValidating = false
    @State private var errorMessage = ""
    @State private var showError = false

    let onSuccess: () -> Void

    var body: some View {
        ZStack {
            // Background
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

            ScrollView {
                VStack(spacing: 0) {
                    Spacer()
                        .frame(height: 80)

                    // Logo/Icon Section
                    logoSection

                    // Title Section
                    titleSection

                    // Server URL Input
                    serverInputSection

                    // Connect Button
                    connectButton

                    // Help Text
                    helpSection

                    Spacer()
                }
                .padding(.horizontal, 30)
            }
        }
        .alert("Connection Error", isPresented: $showError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
        .onAppear {
            if serverURL.isEmpty {
                serverURL = jellyfinService.baseURL
            }
        }
    }

    // MARK: - Logo Section
    private var logoSection: some View {
        Image("AureliaLogo")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 100, height: 100)
            .shadow(color: .appAccent.opacity(0.3), radius: 20, y: 0)
            .padding(.bottom, 40)
    }

    // MARK: - Title Section
    private var titleSection: some View {
        VStack(spacing: 12) {
            Text("Welcome to Aurelia")
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(Color.appText)

            Text("Connect to your Jellyfin server")
                .font(.appBody)
                .foregroundColor(.secondary)
        }
        .padding(.bottom, 50)
    }

    // MARK: - Server Input Section
    private var serverInputSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Server URL")
                .font(.appCaption)
                .foregroundColor(.appAccent)
                .textCase(.uppercase)
                .fontWeight(.semibold)

            HStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .foregroundColor(.appAccent)
                    .font(.title3)

                TextField("https://jellyfin.example.com", text: $serverURL)
                    .textFieldStyle(.plain)
                    .focusEffectDisabled()
                    .foregroundColor(Color.appText)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .tint(.appAccent)
                    .submitLabel(.go)
                    .onSubmit {
                        connect()
                    }
                    .accessibilityLabel("Server URL")

                if !serverURL.isEmpty {
                    Button {
                        serverURL = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .accessibilityLabel("Clear server URL")
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.appControlFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.appAccent.opacity(0.3), lineWidth: 1)
                    )
            )
        }
        .padding(.bottom, 30)
    }

    // MARK: - Connect Button
    private var connectButton: some View {
        Button {
            connect()
        } label: {
            HStack(spacing: 12) {
                if isValidating {
                    ProgressView()
                        .tint(.black)
                } else {
                    Image(systemName: "arrow.right")
                        .font(.title3)
                }

                Text(isValidating ? "Connecting..." : "Connect")
                    .font(.appBody)
                    .fontWeight(.semibold)
            }
            .foregroundColor(.appAccentText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(serverURL.isEmpty ? Color.gray : Color.appAccent)
            )
            .neonGlow(color: serverURL.isEmpty ? .clear : .appAccent, radius: 6)
        }
        .disabled(serverURL.isEmpty || isValidating)
        .accessibilityLabel(isValidating ? "Connecting to server" : "Connect to server")
        .padding(.bottom, 20)
    }

    // MARK: - Help Section
    private var helpSection: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "info.circle")
                    .foregroundColor(.appSecondary.opacity(0.8))
                    .font(.caption)

                Text("Enter your Jellyfin server URL (e.g., https://jellyfin.example.com:8096)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.appSubtleFill)
            )
        }
    }

    // MARK: - Validation
    private func connect() {
        guard !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !isValidating else { return }
        Task {
            await validateAndConnect()
        }
    }

    private func validateAndConnect() async {
        isValidating = true
        errorMessage = ""

        // Basic URL validation
        var urlString = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove trailing slash
        while urlString.hasSuffix("/") {
            urlString = String(urlString.dropLast())
        }

        // Add https:// if no protocol specified
        if !urlString.hasPrefix("http://") && !urlString.hasPrefix("https://") {
            urlString = "https://" + urlString
        }

        // Validate URL format
        guard URL(string: urlString) != nil else {
            errorMessage = "Invalid URL format. Please check your server address."
            showError = true
            isValidating = false
            return
        }

        // Save URL
        jellyfinService.baseURL = urlString

        // Test connection by hitting public system info endpoint
        do {
            let isReachable = try await jellyfinService.checkServerConnectivity()

            if isReachable {
                isValidating = false
                onSuccess()
            } else {
                errorMessage = "Server responded but may not be a Jellyfin server. Please check the URL."
                showError = true
                isValidating = false
            }
        } catch {
            errorMessage = "Could not connect to \(urlString).\n\n\(error.localizedDescription)"
            showError = true
            isValidating = false
        }
    }
}

// MARK: - Preview
#Preview {
    ServerSetupView {
        print("Success!")
    }
}
