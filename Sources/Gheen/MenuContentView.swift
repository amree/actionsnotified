import SwiftUI
import AppKit

struct MenuContentView: View {
    @EnvironmentObject var monitor: Monitor
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    // Explicit State storage, not `@State`: on the macOS 27 SDK `@State` is a
    // macro whose SwiftUIMacros plugin ships only with full Xcode, so it fails
    // to compile with just the Command Line Tools.
    private let filterEventState = State(initialValue: "")
    private var filterEvent: String { filterEventState.wrappedValue }

    private static let rowHeight: CGFloat = 44
    private static let headerHeight: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Picker("Filter by event", selection: filterEventState.projectedValue) {
                Text("All").tag("")
                Text("PR").tag("PR")
                Text("Push").tag("Push")
                Text("Manual").tag("Manual")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)

            if let banner = bannerText {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(banner).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    if monitor.errorBanner == nil {
                        Button("Fix") { showSettings(tab: "repos") }
                    }
                }
                .font(.callout)
                .foregroundStyle(.orange)
                .padding(.vertical, 6).padding(.horizontal, 10)
                .background(.orange.opacity(0.12), in: .rect(cornerRadius: 10))
            }

            runList

            if let t = monitor.lastPolledAt {
                Text("Updated \(t, style: .relative) ago")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 360)
        .onAppear {
            monitor.acknowledge()
            Task { await monitor.poll() }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "smallcircle.filled.circle")
            Text("Gheen").font(.headline)
            if let login = monitor.login {
                Text("@\(login)").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Settings…") { showSettings(tab: "general") }
                    .keyboardShortcut(",")
                Divider()
                Button("Quit Gheen") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "gearshape")
            }
            .menuIndicator(.hidden)
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
            .accessibilityLabel("Settings and Quit")
        }
    }

    /// One banner slot for every error. Global errors (gh missing, signed out,
    /// rerun failed) win over per-repo fetch failures.
    private var bannerText: String? {
        if let e = monitor.errorBanner { return e }
        let failing = monitor.repoErrors.keys.sorted()
        switch failing.count {
        case 0:  return nil
        case 1:  return "\(failing[0]): \(monitor.repoProblem(failing[0]) ?? "can't be reached")"
        default: return "\(failing.count) repositories can't be reached"
        }
    }

    @ViewBuilder private var runList: some View {
        if settings.watchedRepos.isEmpty {
            ContentUnavailableView {
                Label("No repositories watched", systemImage: "eye.slash")
            } actions: {
                Button("Choose Repositories…") { showWindow("welcome") }
            }
            .frame(height: 180)
        } else if filteredActive.isEmpty && filteredRecent.isEmpty {
            ContentUnavailableView(
                filterEvent.isEmpty ? "No runs yet" : "No \(filterEvent) runs",
                systemImage: "circle.dotted",
                description: Text("Runs you start in \(repoList) appear here shortly after they begin."))
            .frame(height: 180)
        } else {
            // Height = what the rows need, capped. A bare ScrollView has no
            // intrinsic height in the auto-sizing MenuBarExtra window, and
            // measuring content to size it loops — so compute it.
            let sections = (filteredActive.isEmpty ? 0 : 1) + (filteredRecent.isEmpty ? 0 : 1)
            let rows = filteredActive.count + filteredRecent.count
            let height = min(CGFloat(rows) * Self.rowHeight + CGFloat(sections) * Self.headerHeight, 420)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !filteredActive.isEmpty { section("Running", runs: filteredActive) }
                    if !filteredRecent.isEmpty { section("Finished", runs: filteredRecent) }
                }
            }
            .frame(height: height)
        }
    }

    private var repoList: String {
        let names = settings.watchedRepos
        return names.count <= 2 ? names.joined(separator: " and ") : "your \(names.count) repositories"
    }

    private var filteredActive: [Run] {
        filterEvent.isEmpty ? monitor.activeRuns
            : monitor.activeRuns.filter { $0.eventLabel == filterEvent }
    }

    private var filteredRecent: [Run] {
        filterEvent.isEmpty ? monitor.recentRuns
            : monitor.recentRuns.filter { $0.eventLabel == filterEvent }
    }

    private func section(_ title: String, runs: [Run]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                .frame(height: Self.headerHeight, alignment: .bottomLeading)
                .padding(.horizontal, 8)
            ForEach(runs) { run in
                RunRow(run: run).frame(height: Self.rowHeight)
            }
        }
    }

    private func showSettings(tab: String) {
        settings.settingsTab = tab
        openSettings()
        bringToFront { $0.identifier?.rawValue.contains("Settings") == true }
    }

    private func showWindow(_ id: String) {
        openWindow(id: id)
        bringToFront { $0.identifier?.rawValue == id }
    }
}

private struct RunRow: View {
    let run: Run
    @EnvironmentObject var monitor: Monitor
    private let hoverState = State(initialValue: false)
    private var hovering: Bool { hoverState.wrappedValue }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
            statusIcon.frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(run.isPR ? run.headBranch : run.displayTitle)
                    .fontWeight(run.isActive ? .semibold : .medium)
                    .lineLimit(1).truncationMode(.middle)
                subtitle
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            }
            .contentShape(.rect)
            .onTapGesture(perform: open)
            // Rerun menu is a sibling of the tappable area, not inside it —
            // a Menu nested in a tap target never gets the click.
            if hovering && run.isCompleted {
                rerunMenu
            }
            trailing.onTapGesture(perform: open)
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .background(hovering ? Color.primary.opacity(0.07) : .clear, in: .rect(cornerRadius: 10))
        .onHover { hoverState.wrappedValue = $0 }
        .help(run.isPR ? run.displayTitle : "")
        .contextMenu {
            Button("Open in Browser", action: open)
            if run.isCompleted {
                Divider()
                rerunButtons
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Open in Browser", open)
        .accessibilityAction(named: "Rerun Failed Jobs") {
            if run.isFailure { monitor.rerun(run, failedOnly: true) }
        }
        .accessibilityAction(named: "Rerun All Jobs") {
            if run.isCompleted { monitor.rerun(run) }
        }
    }

    private var rerunMenu: some View {
        Menu("Rerun") { rerunButtons }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
    }

    @ViewBuilder private var rerunButtons: some View {
        if run.isFailure {
            Button("Rerun Failed Jobs") { monitor.rerun(run, failedOnly: true) }
        }
        Button("Rerun All Jobs") { monitor.rerun(run) }
    }

    @ViewBuilder private var statusIcon: some View {
        if run.isActive {
            if run.isWaiting {
                Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                    .accessibilityLabel("Waiting")
            } else {
                ProgressView().controlSize(.small).scaleEffect(0.8)
                    .accessibilityLabel("Running")
            }
        } else {
            switch run.conclusion {
            case "success":
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    .accessibilityLabel("Succeeded")
            case "failure", "timed_out", "startup_failure":
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    .accessibilityLabel("Failed")
            default:
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    .accessibilityLabel(run.conclusion?.capitalized ?? "Finished")
            }
        }
    }

    private var subtitle: Text {
        let rest = run.isPR
            ? "\(run.repoName) · \(run.workflowName)"
            : "\(run.repoName) · \(run.headBranch) · \(run.workflowName)"
        if run.isFailure {
            return Text("\(Text("Failed").foregroundStyle(.red).fontWeight(.semibold)) · \(rest)")
        }
        if run.status == "waiting" { return Text("Waiting for approval · \(rest)") }
        if run.conclusion == "cancelled" { return Text("Cancelled · \(rest)") }
        return Text(rest)
    }

    @ViewBuilder private var trailing: some View {
        if run.isActive {
            // Elapsed time of the current attempt; run_started_at resets on rerun.
            let start = run.runStartedAt ?? run.createdAt
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(Self.elapsed(ctx.date.timeIntervalSince(start)))
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
        } else {
            Text(run.timeAgo.replacingOccurrences(of: " ago", with: ""))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func open() {
        if let url = URL(string: run.url) { NSWorkspace.shared.open(url) }
    }

    static func elapsed(_ s: TimeInterval) -> String {
        let t = max(0, Int(s))
        return t >= 3600
            ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
            : String(format: "%d:%02d", t / 60, t % 60)
    }
}
