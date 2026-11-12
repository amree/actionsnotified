import SwiftUI
import AppKit

/// First-run window: checks gh, then picks repos to watch. Shown at launch while
/// no repos are watched (a MenuBarExtra popover can't open itself).
struct OnboardingView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var monitor: Monitor
    @Environment(\.dismissWindow) private var dismissWindow

    private enum Check { case checking, ok(String), failed }
    private struct Candidate: Hashable { let name: String; let pushedAt: Date? }

    // Explicit State storage, not `@State` — see MenuContentView.
    private let ghState = State(initialValue: Check.checking)
    private let loginState = State(initialValue: Check.checking)
    private let candidatesState = State(initialValue: [Candidate]())
    private let pickedState = State(initialValue: Set<String>())
    private let newRepoState = State(initialValue: "")

    private var picked: Set<String> { pickedState.wrappedValue }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "smallcircle.filled.circle").font(.largeTitle)
                Text("Welcome to ActionsNotified").font(.title2).bold()
                Text("Watch your GitHub Actions runs. Uses the GitHub CLI you already have. Nothing new to sign in to.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .top], 24)

            Form {
                Section {
                    ghRow
                    loginRow
                }
                if case .ok = loginState.wrappedValue {
                    Section("Recently pushed — yours and your orgs'") {
                        ForEach(candidatesState.wrappedValue, id: \.self) { c in
                            Toggle(isOn: binding(for: c.name)) {
                                HStack {
                                    Text(c.name).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    if let d = c.pushedAt {
                                        Text(d.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                        HStack {
                            TextField("Another repo", text: newRepoState.projectedValue, prompt: Text("owner/repo"))
                                .labelsHidden()
                                .onSubmit(addTyped)
                            Button("Add", action: addTyped)
                                .disabled(!RepoSettingsValidation.isValid(newRepoState.wrappedValue))
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            HStack {
                Text("Change these later in Settings.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(picked.isEmpty ? "Watch repositories"
                       : "Watch \(picked.count) \(picked.count == 1 ? "repository" : "repositories")",
                       action: finish)
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(picked.isEmpty)
            }
            .padding([.horizontal, .bottom], 24)
        }
        .frame(width: 440, height: 620)
        .task { await recheck() }
        // Re-check when the user comes back from Terminal after installing gh.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            if case .ok = loginState.wrappedValue { return }
            Task { await recheck() }
        }
        .onAppear { bringToFront { $0.identifier?.rawValue == "welcome" } }
    }

    @ViewBuilder private var ghRow: some View {
        switch ghState.wrappedValue {
        case .checking:
            Label("Looking for the GitHub CLI…", systemImage: "circle.dotted")
        case .ok(let path):
            Label { Text("GitHub CLI found"); Text(path).font(.caption.monospaced()) } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        case .failed:
            VStack(alignment: .leading, spacing: 8) {
                Label { Text("GitHub CLI not found"); Text("Install it with Homebrew, then sign in.") } icon: {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                }
                commandRow("brew install gh")
                commandRow("gh auth login")
                HStack {
                    Button("Check again") { Task { await recheck() } }
                    Button("Locate gh…", action: locateGh)
                }
                Text("Checks again by itself when you come back to this window.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var loginRow: some View {
        switch (ghState.wrappedValue, loginState.wrappedValue) {
        case (_, .ok(let login)):
            Label { Text("Signed in as @\(login)"); Text("github.com") } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        case (.ok, .failed):
            VStack(alignment: .leading, spacing: 8) {
                Label { Text("Not signed in to GitHub"); Text("Sign in with the GitHub CLI, then come back.") } icon: {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                }
                commandRow("gh auth login")
            }
        default:
            Label("Signed in to GitHub", systemImage: "circle").foregroundStyle(.secondary)
        }
    }

    private func commandRow(_ cmd: String) -> some View {
        HStack {
            Text(cmd).font(.callout.monospaced()).textSelection(.enabled)
            Spacer()
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(cmd, forType: .string)
            }
            .controlSize(.small)
        }
    }

    private func binding(for repo: String) -> Binding<Bool> {
        Binding(
            get: { picked.contains(repo) },
            set: { on in
                if on { pickedState.wrappedValue.insert(repo) } else { pickedState.wrappedValue.remove(repo) }
            })
    }

    private func recheck() async {
        guard let path = await monitor.ghPath() else {
            ghState.wrappedValue = .failed
            loginState.wrappedValue = .checking
            return
        }
        ghState.wrappedValue = .ok(path)
        guard let login = try? await monitor.checkLogin() else {
            loginState.wrappedValue = .failed
            return
        }
        loginState.wrappedValue = .ok(login)
        let repos = (try? await monitor.recentRepos()) ?? []
        candidatesState.wrappedValue = repos.map { Candidate(name: $0.name, pushedAt: $0.pushedAt) }
        if picked.isEmpty {
            pickedState.wrappedValue = Set(settings.watchedRepos.isEmpty
                ? repos.prefix(2).map(\.name) : settings.watchedRepos)
        }
    }

    private func addTyped() {
        let repo = newRepoState.wrappedValue.trimmingCharacters(in: .whitespaces)
        guard RepoSettingsValidation.isValid(repo) else { return }
        if !candidatesState.wrappedValue.contains(where: { $0.name == repo }) {
            candidatesState.wrappedValue.append(Candidate(name: repo, pushedAt: nil))
        }
        pickedState.wrappedValue.insert(repo)
        newRepoState.wrappedValue = ""
    }

    private func locateGh() {
        let panel = NSOpenPanel()
        panel.message = "Choose the gh executable"
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.ghPath = url.path
        monitor.rebuildClient()
        Task { await recheck() }
    }

    private func finish() {
        // Keep the user's chosen order: candidates first, as listed.
        let ordered = candidatesState.wrappedValue.map(\.name).filter(picked.contains)
        settings.watchedRepos = ordered + picked.subtracting(ordered).sorted()
        Task { await monitor.poll() }
        dismissWindow(id: "welcome")
    }
}

/// An LSUIElement app's windows open behind the frontmost app — activation is
/// cooperative — so pull the window forward explicitly.
@MainActor func bringToFront(_ match: @escaping (NSWindow) -> Bool) {
    DispatchQueue.main.async {
        guard let w = NSApp.windows.first(where: match) else { return }
        w.orderFrontRegardless()
        w.makeKey()
        // Deprecated, but on macOS 26 the cooperative `activate()` is ignored
        // here and the window stays inactive behind the frontmost app.
        NSApp.activate(ignoringOtherApps: true)
    }
}

enum RepoSettingsValidation {
    static func isValid(_ s: String) -> Bool {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: "/")
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty
    }
}
