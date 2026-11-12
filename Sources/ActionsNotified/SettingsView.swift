import SwiftUI
import AppKit
import ServiceManagement

/// The Settings window: General and Repositories tabs.
struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        TabView(selection: $settings.settingsTab) {
            Tab("General", systemImage: "gearshape", value: "general") {
                GeneralSettings()
            }
            Tab("Repositories", systemImage: "book.closed", value: "repos") {
                RepoSettings()
            }
        }
        .frame(width: 520)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var monitor: Monitor
    // Explicit State storage, not `@State` — see MenuContentView.
    private let launchAtLoginState = State(initialValue: SMAppService.mainApp.status == .enabled)
    private let ghPathState = State(initialValue: String?.none)

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLoginState.wrappedValue },
                    set: setLaunchAtLogin))
                    .disabled(Monitor.demo)
                Picker("Notify me when", selection: $settings.notifyMode) {
                    Text("Any run finishes").tag("all")
                    Text("A run fails").tag("failures")
                    Text("Never").tag("never")
                }
            }
            Section {
                Picker("Check for runs every", selection: $settings.pollInterval) {
                    Text("15 seconds").tag(15.0)
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("2 minutes").tag(120.0)
                }
                .onChange(of: settings.pollInterval) { monitor.settingsChanged() }
            } footer: {
                Text("Slows to every 2 minutes while nothing is running.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent {
                    HStack {
                        if !settings.ghPath.isEmpty {
                            Button("Use Default", action: resetGh)
                        }
                        Button("Change…", action: chooseGh)
                    }
                } label: {
                    Text("GitHub CLI")
                    Text(ghPathState.wrappedValue ?? "Not found")
                        .font(.caption.monospaced())
                }
                LabeledContent {
                    Button("Open", action: openLog)
                } label: {
                    Text("Activity log")
                    Text("Recent activity, for troubleshooting")
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .task { ghPathState.wrappedValue = await monitor.ghPath() }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            CommandLog.append("error: launch at login — \(error.localizedDescription)")
        }
        launchAtLoginState.wrappedValue = SMAppService.mainApp.status == .enabled
    }

    private func chooseGh() {
        let panel = NSOpenPanel()
        panel.message = "Choose the gh executable"
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.ghPath = url.path
        monitor.rebuildClient()
        Task {
            ghPathState.wrappedValue = await monitor.ghPath()
            await monitor.poll()
        }
    }

    /// Drops the custom path so gh is found on PATH again.
    private func resetGh() {
        settings.ghPath = ""
        monitor.rebuildClient()
        Task {
            ghPathState.wrappedValue = await monitor.ghPath()
            await monitor.poll()
        }
    }

    /// Opens the gh command log, or reveals its folder if no poll has logged yet.
    private func openLog() {
        guard let url = CommandLog.fileURL else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }
}

private struct RepoSettings: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var monitor: Monitor
    private let selectionState = State(initialValue: String?.none)
    private let newRepoState = State(initialValue: "")
    private let addingState = State(initialValue: false)
    private var newRepo: String { newRepoState.wrappedValue }

    private var addForm: some View {
        HStack {
            TextField("Repository", text: newRepoState.projectedValue, prompt: Text("owner/repo"))
                .labelsHidden()
                .frame(width: 220)
                .onSubmit(add)
            Button("Add", action: add)
                .keyboardShortcut(.defaultAction)
                .disabled(!RepoSettingsValidation.isValid(newRepo))
        }
        .padding(12)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Only runs you start are shown.")
                .font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                List(selection: selectionState.projectedValue) {
                    ForEach(settings.watchedRepos, id: \.self) { repo in
                        HStack {
                            Text(repo)
                            if monitor.repoProblem(repo) != nil {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            }
                            Spacer()
                            detail(for: repo)
                        }
                    }
                }
                .listStyle(.bordered)
                .alternatingRowBackgrounds()
                .onDeleteCommand(perform: remove)
                // The standard Mac +/− pair under a list.
                HStack(spacing: 2) {
                    Button { addingState.wrappedValue = true } label: {
                        Image(systemName: "plus").frame(width: 22, height: 20)
                    }
                    .accessibilityLabel("Add Repository")
                    .popover(isPresented: addingState.projectedValue, arrowEdge: .bottom) { addForm }
                    Button(action: remove) {
                        Image(systemName: "minus").frame(width: 22, height: 20)
                    }
                    .accessibilityLabel("Remove Repository")
                    .disabled(selectionState.wrappedValue == nil)
                }
                .buttonStyle(.borderless)
                .padding(.top, 6)
            }
            .frame(height: 250)
        }
        .padding(20)
    }

    @ViewBuilder private func detail(for repo: String) -> some View {
        if let problem = monitor.repoProblem(repo) {
            Text(problem).font(.caption).foregroundStyle(.orange)
        } else if let d = monitor.lastRunDate(for: repo) {
            Text("last run \(d.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func add() {
        let repo = newRepo.trimmingCharacters(in: .whitespaces)
        guard RepoSettingsValidation.isValid(repo), !settings.watchedRepos.contains(repo) else { return }
        settings.watchedRepos.append(repo)
        newRepoState.wrappedValue = ""
        addingState.wrappedValue = false
        Task { await monitor.poll() }
    }

    private func remove() {
        guard let repo = selectionState.wrappedValue else { return }
        settings.watchedRepos.removeAll { $0 == repo }
        monitor.forgetRepo(repo)
        selectionState.wrappedValue = nil
        Task { await monitor.poll() }
    }
}
