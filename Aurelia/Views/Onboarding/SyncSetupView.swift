//
//  SyncSetupView.swift
//  Aurelia
//
//  Confirms the server can actually serve a library before the app opens.
//
//  AureliaSync is the only transport for artists, albums, tracks, playlists
//  and genres. Without it there is nothing to browse, so this stands between
//  signing in and the app rather than letting someone discover the problem as
//  a failed sync with no stated cause.
//

import SwiftUI

struct SyncSetupView: View {
    @ObservedObject private var jellyfinService = JellyfinService.shared

    @State private var phase: Phase = .checking
    @State private var steps: [Step] = Step.plan(update: false)
    @State private var failure: String?
    /// Held back briefly so a check that passes in a couple of hundred
    /// milliseconds never puts a screen up and takes it away again.
    @State private var showsChecking = false

    /// Called once the plugin is confirmed present and healthy.
    let onReady: () -> Void

    enum Phase: Equatable {
        case checking
        /// Installed but not usable, or the check itself failed.
        case blocked(String)
        /// Missing or too old, and this account can do something about it.
        case needsInstall(update: Bool)
        /// Missing or too old, and it needs someone with the keys to the server.
        case needsAdministrator(update: Bool)
        case working
    }

    /// One line of the checklist. The list is shown before anything happens,
    /// so the restart is never a surprise, and ticked off as it goes.
    struct Step: Identifiable, Equatable {
        enum State: Equatable {
            case pending
            case running
            case done
            case failed
        }

        let id: String
        let title: String
        var state: State = .pending

        static func plan(update: Bool) -> [Step] {
            [
                Step(id: "install", title: update
                    ? "Update the Aurelia Sync plugin"
                    : "Install the Aurelia Sync plugin"),
                Step(id: "restart", title: "Restart your Jellyfin server"),
                Step(id: "wait", title: "Wait for the server to come back"),
                Step(id: "verify", title: "Check that syncing is available")
            ]
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.appBackground, Color.appMidBackground, Color.appBackground],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                Image("AureliaLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 72, height: 72)
                    .shadow(color: .appAccent.opacity(0.3), radius: 20, y: 0)

                content

                Spacer()

                if phase != .working {
                    signOutButton
                }
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 24)
        }
        .task {
            await check()
        }
        .task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard phase == .checking else { return }
            withAnimation(.easeOut(duration: 0.2)) { showsChecking = true }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .checking:
            if showsChecking {
                VStack(spacing: 16) {
                    ProgressView()
                        .tint(.appAccent)
                        .scaleEffect(1.3)
                    Text("Checking your server")
                        .font(.appBody)
                        .foregroundColor(.appTextSecondary)
                }
                .transition(.opacity)
            }

        case .needsInstall(let update):
            VStack(spacing: 24) {
                heading(
                    update ? "Your server needs an update" : "One thing to set up",
                    detail: update
                        ? "This version of Aurelia needs a newer Aurelia Sync than the one on your server. Here is what will happen:"
                        : "Aurelia keeps your library in step through a small Jellyfin plugin. Here is what will happen:"
                )
                checklist
                primaryButton(update ? "Update and Restart" : "Install and Restart") {
                    Task { await runSetup() }
                }
                repositoryLink
            }

        case .working:
            VStack(spacing: 24) {
                heading(
                    "Setting up",
                    detail: "This takes a minute. Your server will be briefly unavailable while it restarts."
                )
                checklist
                if let failure {
                    errorText(failure)
                    primaryButton("Try Again") {
                        Task { await runSetup() }
                    }
                }
            }

        case .needsAdministrator(let update):
            VStack(spacing: 24) {
                heading(
                    "Ask your server administrator",
                    detail: update
                        ? "This server's Aurelia Sync plugin is older than this version of Aurelia needs, and updating it takes an administrator account. Until it is updated there is no library to show."
                        : "Aurelia needs the Aurelia Sync plugin on this Jellyfin server, and installing it takes an administrator account. Until it is installed there is no library to show."
                )
                primaryButton("Check Again") {
                    Task { await check() }
                }
                repositoryLink
            }

        case .blocked(let message):
            VStack(spacing: 24) {
                heading(
                    "Cannot reach the plugin",
                    detail: "Aurelia could not confirm that this server can sync your library."
                )
                errorText(message)
                primaryButton("Try Again") {
                    Task { await check() }
                }
            }
        }
    }

    private func heading(_ title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.title2.weight(.bold))
                .foregroundColor(Color.appText)
                .multilineTextAlignment(.center)

            Text(detail)
                .font(.appBody)
                .foregroundColor(.appTextSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(steps) { step in
                HStack(spacing: 12) {
                    stepIcon(for: step.state)
                        .frame(width: 22)

                    Text(step.title)
                        .font(.appBody)
                        .foregroundColor(step.state == .pending ? .appTextSecondary : .appText)

                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(step.title), \(accessibilityState(step.state))")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.appControlFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.appAccent.opacity(0.25), lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private func stepIcon(for state: Step.State) -> some View {
        switch state {
        case .pending:
            Image(systemName: "circle")
                .foregroundColor(.appTextMuted)
        case .running:
            ProgressView()
                .tint(.appAccent)
                .scaleEffect(0.8)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.appSuccess)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundColor(.appWarning)
        }
    }

    private func accessibilityState(_ state: Step.State) -> String {
        switch state {
        case .pending: return "not started"
        case .running: return "in progress"
        case .done: return "done"
        case .failed: return "failed"
        }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.appBody)
                .fontWeight(.semibold)
                .foregroundColor(.appAccentText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.appAccent))
        }
        .accessibilityIdentifier("sync-setup-primary")
    }

    private var repositoryLink: some View {
        Link(destination: AureliaSyncClient.repositoryPage) {
            Label("Aurelia Sync on GitHub", systemImage: "arrow.up.right.square")
                .font(.appCaption)
                .foregroundColor(.appAccent)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityIdentifier("sync-setup-repository")
    }

    private func errorText(_ message: String) -> some View {
        Text(message)
            .font(.appCaption)
            .foregroundColor(.appWarning)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var signOutButton: some View {
        Button("Sign Out") {
            jellyfinService.signOut()
        }
        .font(.appCaption)
        .foregroundColor(.appTextSecondary)
    }

    // MARK: - Work

    private func check() async {
        phase = .checking
        failure = nil

        do {
            let status = try await AureliaSyncClient.shared.status()
            guard status.enabled && status.healthy else {
                phase = .blocked(status.healthDetail ?? "The plugin is installed but not running.")
                return
            }
            guard status.isCompatible else {
                // A version mismatch is as disqualifying as a missing plugin,
                // and saying so here beats letting the first sync fail with
                // nothing but "no common protocol or schema version".
                guard status.isOlderThanClient else {
                    phase = .blocked(
                        "This server runs Aurelia Sync \(status.pluginVersion), which is newer than "
                        + "this version of Aurelia understands. Update the app to continue."
                    )
                    return
                }
                await requestSetup(update: true)
                return
            }
            onReady()
        } catch AureliaSyncError.required {
            await requestSetup(update: false)
        } catch {
            phase = .blocked(error.localizedDescription)
        }
    }

    /// Offers the install, or explains who has to do it.
    private func requestSetup(update: Bool) async {
        steps = Step.plan(update: update)
        do {
            phase = try await AureliaSyncPluginManager.shared.currentUserIsAdministrator()
                ? .needsInstall(update: update)
                : .needsAdministrator(update: update)
        } catch {
            // A check that cannot complete is not permission to carry on: the
            // library would fail later with less to go on than here.
            phase = .blocked(error.localizedDescription)
        }
    }

    private func runSetup() async {
        phase = .working
        failure = nil
        // Reset the ticks without rewriting the titles, which already say
        // whether this is an install or an update.
        steps = steps.map { step in
            var reset = step
            reset.state = .pending
            return reset
        }

        guard await perform("install", { try await AureliaSyncPluginManager.shared.install() }) else { return }
        guard await perform("restart", { try await AureliaSyncPluginManager.shared.restartServer() }) else { return }

        setState("wait", .running)
        guard await AureliaSyncPluginManager.shared.waitForServer() else {
            setState("wait", .failed)
            failure = "The server did not come back. Check that it restarted, then try again."
            return
        }
        setState("wait", .done)

        setState("verify", .running)
        do {
            let status = try await AureliaSyncClient.shared.status()
            guard status.enabled && status.healthy else {
                setState("verify", .failed)
                failure = status.healthDetail ?? "The plugin is installed but not running yet."
                return
            }
            setState("verify", .done)
            onReady()
        } catch {
            setState("verify", .failed)
            failure = error.localizedDescription
        }
    }

    private func perform(_ id: String, _ work: () async throws -> Void) async -> Bool {
        setState(id, .running)
        do {
            try await work()
            setState(id, .done)
            return true
        } catch {
            setState(id, .failed)
            failure = error.localizedDescription
            return false
        }
    }

    private func setState(_ id: String, _ state: Step.State) {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            steps[index].state = state
        }
    }
}

#Preview {
    SyncSetupView(onReady: {})
}
