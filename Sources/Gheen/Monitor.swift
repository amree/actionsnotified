import Foundation
import Combine
import AppKit

enum Aggregate {
    case idle, active, failure
}

@MainActor
final class Monitor: ObservableObject {
    @Published private(set) var activeRuns: [Run] = []
    @Published private(set) var recentRuns: [Run] = []
    @Published private(set) var aggregate: Aggregate = .idle
    @Published private(set) var errorBanner: String?
    @Published private(set) var login: String?
    @Published private(set) var lastPolledAt: Date?
    /// Repos whose last fetch failed, with the reason. Shown as one banner in the popover.
    @Published private(set) var repoErrors: [String: String] = [:]

    private let settings: SettingsStore
    private let notifier: NotificationManager
    private var client: GitHubClient

    private var timer: Timer?
    private var isPolling = false
    private var currentPollStartedAt: Date?
    private var pollGeneration = 0
    // Watchdog: if a poll stays in flight longer than this, it's wedged on a
    // blocking call the GitHubClient timeouts didn't catch (login-shell path
    // resolution, or a gh child holding the output pipe open). Abandon it and
    // start fresh so polling — and notifications — recover.
    private let maxPollDuration: TimeInterval = 60
    private var hasUnackedFailure = false
    private var backoffMultiplier: Double = 1.0
    private let maxBackoffInterval: TimeInterval = 120

    // Per-repo state: baseline, active-key set, and poll-start cursor are all
    // scoped to each repo independently. This prevents a failed repo from
    // corrupting the cursor or seenActiveKeys for repos that did succeed, and
    // ensures a repo added after startup gets its own silent baseline pass.
    private struct RepoState {
        var baselined = false
        var seenActiveKeys: Set<String> = []
        var prevPollStartedAt: Date?
        // Last set of runs this repo actually rendered. Doubles as the
        // fallback source when a poll can't fully account for the repo — see
        // `Monitor.reconcile`.
        var lastKnownRuns: [Run] = []
    }
    private var repoStates: [String: RepoState] = [:]
    private var sleepStart: Date?

    init(settings: SettingsStore, notifier: NotificationManager) {
        self.settings = settings
        self.notifier = notifier
        self.client = GitHubClient(
            overridePath: settings.ghPath.isEmpty ? nil : settings.ghPath)
        observeSleepWake()
    }

    // MARK: - Sleep / wake

    /// Logs sleep/wake explicitly (so a log gap has a documented cause instead of
    /// looking like a stall) and forces an immediate, un-backed-off poll on wake —
    /// belt-and-suspenders alongside the timer's own catch-up behavior on resume.
    private func observeSleepWake() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.sleepStart = Date()
                CommandLog.append("system sleeping")
            }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let asleep = self.sleepStart.map { Int(Date().timeIntervalSince($0)) }
                self.sleepStart = nil
                CommandLog.append("system woke" + (asleep.map { " — asleep \($0)s" } ?? ""))
                self.backoffMultiplier = 1.0
                self.scheduleTimer()
                Task { await self.poll() }
            }
        }
    }

    var iconName: String {
        switch aggregate {
        case .active:  return "circle.dotted"
        case .failure: return "circle.fill"
        case .idle:    return "circle"
        }
    }

    // MARK: - Lifecycle

    /// `open Gheen.app --args -demo`: fake runs in every state, no polling, and a
    /// preview window with the popover content. For UI checks only.
    static let demo = ProcessInfo.processInfo.arguments.contains("-demo")

    func start() {
        if Monitor.demo { loadDemo(); return }
        CommandLog.append("monitor started — \(settings.watchedRepos.count) repo(s), interval \(Int(settings.pollInterval))s")
        if login == nil { login = settings.cachedLogin }
        Task { await poll() }
        scheduleTimer()
    }

    func scheduleTimer() {
        timer?.invalidate()
        let interval = min(settings.pollInterval * backoffMultiplier, maxBackoffInterval)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func forgetRepo(_ repo: String) {
        repoStates.removeValue(forKey: repo)
        repoErrors.removeValue(forKey: repo)
    }

    /// Short reason a repo can't be fetched, or nil when it's fine.
    func repoProblem(_ repo: String) -> String? {
        guard let msg = repoErrors[repo] else { return nil }
        return msg.contains("404") || msg.localizedCaseInsensitiveContains("not found")
            ? "not found or no access" : "can't be reached"
    }

    /// A setting that affects polling changed: start again at the base interval.
    func settingsChanged() {
        backoffMultiplier = 1.0
        scheduleTimer()
    }

    /// Most recent run of ours seen in `repo`, for the Settings repo list.
    func lastRunDate(for repo: String) -> Date? {
        repoStates[repo]?.lastKnownRuns.map(\.updatedAt).max()
    }

    // Passthroughs for the first-run window.
    func ghPath() async -> String? { await client.resolvedPath() }
    func recentRepos() async throws -> [(name: String, pushedAt: Date?)] { try await client.recentRepos() }
    func checkLogin() async throws -> String {
        let resolved = try await client.currentLogin()
        login = resolved
        settings.cachedLogin = resolved
        return resolved
    }

    func rerun(_ run: Run, failedOnly: Bool = false) {
        if Monitor.demo { return }
        Task {
            do {
                try await client.rerunRun(id: run.databaseId, repo: run.repo, failedOnly: failedOnly)
                await poll()
            } catch {
                errorBanner = message(for: error)
            }
        }
    }

    func rebuildClient() {
        client = GitHubClient(overridePath: settings.ghPath.isEmpty ? nil : settings.ghPath)
        login = settings.cachedLogin
        backoffMultiplier = 1.0
        scheduleTimer()
    }

    /// Called when the dropdown opens — clears red failure state and resets backoff.
    func acknowledge() {
        if hasUnackedFailure {
            hasUnackedFailure = false
            recomputeAggregate()
        }
        if backoffMultiplier != 1.0 {
            backoffMultiplier = 1.0
            scheduleTimer()
        }
    }

    // MARK: - Polling

    func poll() async {
        if Monitor.demo { return }
        if isPolling {
            // Normally skip an overlapping tick — but if the in-flight poll has been
            // running too long it's wedged; abandon it and fall through to a fresh
            // poll. Bumping the generation makes the stuck poll bail before it
            // mutates any state, should it ever unblock.
            if let started = currentPollStartedAt,
               Date().timeIntervalSince(started) > maxPollDuration {
                pollGeneration &+= 1
                CommandLog.append(
                    "poll watchdog — abandoning stuck poll (\(Int(Date().timeIntervalSince(started)))s)")
            } else {
                CommandLog.append("poll skipped — previous still running")
                return
            }
        }
        isPolling = true
        let gen = pollGeneration
        currentPollStartedAt = Date()
        defer {
            // Only clear if we're still current — a resumed, abandoned poll must not
            // reset the guard the fresh poll is holding.
            if gen == pollGeneration {
                isPolling = false
                currentPollStartedAt = nil
            }
        }

        let pollStart = Date()

        if login == nil {
            do {
                let resolved = try await client.currentLogin()
                login = resolved
                settings.cachedLogin = resolved
            } catch {
                setError(error)
                return
            }
        }
        guard let user = login else { return }

        let repos = settings.watchedRepos
        guard !repos.isEmpty else {
            CommandLog.append("idle — no repos watched")
            activeRuns = []
            recentRuns = []
            errorBanner = nil
            repoErrors = [:]
            recomputeAggregate()
            return
        }

        var freshByRepo: [String: [Run]] = [:]
        var repoErrors: [String: Error] = [:]
        // Serial loop — avoids @MainActor + withTaskGroup result-collection issues in Swift 5.
        // With typical repo counts (1-5) the latency difference is negligible.
        for repo in repos {
            do {
                freshByRepo[repo] = try await client.listRuns(repo: repo, user: user)
            } catch {
                repoErrors[repo] = error
            }
        }
        // If the watchdog abandoned this poll while it was awaiting gh, bail before
        // touching any shared state or firing stale notifications.
        guard gen == pollGeneration else { return }

        // A poll that can't fully account for a repo — a hard `gh api` failure,
        // or a 200 response GitHub's actor= search index hasn't caught up on
        // yet and so is silently missing a still-active run — must not regress
        // what's displayed for it. Reconcile against what that repo last
        // rendered instead of taking this tick's response at face value.
        var repoResults: [String: [Run]] = [:]
        for repo in repos {
            let lastKnown = repoStates[repo]?.lastKnownRuns ?? []
            let (runs, carriedOver) = Monitor.reconcile(fresh: freshByRepo[repo], lastKnown: lastKnown)
            repoResults[repo] = runs
            if !carriedOver.isEmpty {
                let reason = repoErrors[repo] != nil ? "repo fetch failed" : "missing from a successful response"
                CommandLog.append(
                    "carried forward \(carriedOver.count) run(s) for \(repo) (\(reason)): " +
                    carriedOver.map(\.runKey).joined(separator: ", "))
            }
        }

        // gh missing / signed out fail every repo the same way — that's one
        // global problem, not N repo problems.
        if let global = repoErrors.values.first(where: {
            if case GitHubError.ghNotFound = $0 { return true }
            if case GitHubError.notAuthenticated = $0 { return true }
            return false
        }) {
            setError(global)
            self.repoErrors = [:]
        } else {
            errorBanner = nil
            self.repoErrors = repoErrors.mapValues(message(for:))
        }

        processRepos(repoResults, pollStart: pollStart)

        let newMultiplier = activeRuns.isEmpty
            ? min(backoffMultiplier * 2, maxBackoffInterval / max(settings.pollInterval, 1))
            : 1.0
        if newMultiplier != backoffMultiplier {
            backoffMultiplier = newMultiplier
            scheduleTimer()
            if activeRuns.isEmpty {
                let interval = min(settings.pollInterval * newMultiplier, maxBackoffInterval)
                CommandLog.append("idle — next poll in \(Int(interval))s")
            }
        }
    }

    private struct PendingNotification {
        let title: String
        let body: String
        let url: String
        let isFailure: Bool
    }

    private func processRepos(_ repoResults: [String: [Run]], pollStart: Date) {
        var notified = settings.notifiedKeys
        var allActive: [Run] = []
        var allFinished: [Run] = []
        var pending: [PendingNotification] = []

        for (repo, runs) in repoResults {
            var state = repoStates[repo, default: RepoState()]
            let active = runs.filter { $0.isActive }
            let finished = runs.filter { $0.isCompleted }

            if !state.baselined {
                // First successful poll for this repo — record all finished runs
                // silently so we never notify for pre-existing completions.
                state.baselined = true
                for run in finished { notified.insert(run.runKey) }
            } else {
                let cursor = state.prevPollStartedAt ?? pollStart
                for run in finished {
                    let key = run.runKey
                    if notified.contains(key) { continue }
                    let wasActive = state.seenActiveKeys.contains(key)
                    // Notify on normal active→completed transition OR short run
                    // that started+finished between polls (updatedAt ≥ cursor).
                    if wasActive || run.updatedAt >= cursor {
                        pending.append(PendingNotification(
                            title: notificationTitle(run),
                            body: notificationBody(run),
                            url: run.url,
                            isFailure: run.isFailure))
                        notified.insert(key)
                        if run.isFailure { hasUnackedFailure = true }
                    }
                }
            }

            state.seenActiveKeys = Set(active.map { $0.runKey })
            state.prevPollStartedAt = pollStart
            state.lastKnownRuns = runs
            repoStates[repo] = state

            allActive.append(contentsOf: active)
            allFinished.append(contentsOf: finished)
        }

        switch settings.notifyMode {
        case "never":    pending = []
        case "failures": pending = pending.filter(\.isFailure)
        default:         break
        }

        // Fire notifications — batch into one summary if multiple completed this poll.
        if pending.count == 1 {
            let n = pending[0]
            notifier.notify(title: n.title, body: n.body, url: n.url)
        } else if pending.count > 1 {
            let failures = pending.filter(\.isFailure).count
            let successes = pending.count - failures
            var parts: [String] = []
            if successes > 0 { parts.append("\(successes) succeeded") }
            if failures > 0 { parts.append("\(failures) failed") }
            let anchor = pending.first(where: \.isFailure) ?? pending[0]
            notifier.notify(
                title: "\(pending.count) workflows finished",
                body: parts.joined(separator: ", "),
                url: anchor.url)
        }

        settings.notifiedKeys = prune(notified)
        activeRuns = allActive.sorted { $0.updatedAt > $1.updatedAt }
        recentRuns = Array(allFinished.sorted { $0.updatedAt > $1.updatedAt }.prefix(10))
        lastPolledAt = Date()
        recomputeAggregate()
    }

    private func loadDemo() {
        let now = Date()
        func run(_ id: Int, _ status: String, _ conclusion: String?, title: String, branch: String,
                 event: String, workflow: String, repo: String, ago: TimeInterval) -> Run {
            var r = Run(databaseId: id, attempt: 1, status: status, conclusion: conclusion,
                        workflowName: workflow, displayTitle: title, headBranch: branch, event: event,
                        url: "https://github.com/\(repo)/actions", createdAt: now - ago, updatedAt: now - ago)
            r.repo = repo
            r.runStartedAt = now - ago
            return r
        }
        login = "you"
        activeRuns = [
            run(1, "in_progress", nil, title: "Retry billing", branch: "feat/billing-retry", event: "pull_request", workflow: "CI", repo: "acme/api", ago: 134),
            run(2, "waiting", nil, title: "Bump version to 2.4.1", branch: "main", event: "workflow_dispatch", workflow: "Release", repo: "acme/web", ago: 41),
        ]
        recentRuns = [
            run(3, "completed", "failure", title: "Fix session timeout", branch: "fix/session-timeout", event: "pull_request", workflow: "CI", repo: "acme/api", ago: 180),
            run(4, "completed", "success", title: "Deploy production", branch: "main", event: "push", workflow: "Deploy", repo: "acme/web", ago: 1080),
            run(5, "completed", "success", title: "Bump deps", branch: "chore/deps-bump", event: "pull_request", workflow: "Lint", repo: "acme/infra", ago: 3600),
            run(6, "completed", "cancelled", title: "Run e2e suite", branch: "main", event: "workflow_dispatch", workflow: "E2E", repo: "acme/web", ago: 7200),
        ]
        repoErrors = ["old-org/legacy": "HTTP 404: Not Found"]
        lastPolledAt = now - 12
        recomputeAggregate()
    }

    // MARK: - Helpers

    private func recomputeAggregate() {
        if !activeRuns.isEmpty {
            aggregate = .active
        } else if hasUnackedFailure {
            aggregate = .failure
        } else {
            aggregate = .idle
        }
    }

    private func setError(_ error: Error) {
        let msg = message(for: error)
        CommandLog.append("error: \(msg)")
        errorBanner = msg
    }

    private func message(for error: Error) -> String {
        (error as? GitHubError)?.errorDescription ?? error.localizedDescription
    }

    private func prune(_ keys: Set<String>) -> Set<String> {
        keys.count > 1000 ? Set(Array(keys).suffix(1000)) : keys
    }

    private func notificationTitle(_ run: Run) -> String {
        "\(run.conclusionEmoji) \(run.displayTitle)"
    }

    private func notificationBody(_ run: Run) -> String {
        "\(run.repo) · \(run.headBranch) · \(run.workflowName)"
    }

    /// The single place that decides what "this repo's runs" means for a poll,
    /// given what actually came back for it.
    ///
    /// `fresh == nil` is a hard `gh api` failure — nothing came back at all, so
    /// the entire last-known list carries forward (active *and*
    /// recently-finished, so the failing repo doesn't vanish from the capped
    /// "recently finished" list and let another repo's older runs crowd in).
    ///
    /// `fresh != nil` is a successful response, but GitHub's `actor=` search
    /// index can lag a poll behind real state and silently omit a still-active
    /// run. Only *active* runs missing from an otherwise-successful response
    /// are carried forward — a finished run that ages out of a real page is
    /// expected and correct, not a gap to paper over.
    ///
    /// Pure and MainActor-free so it's directly unit-testable. Internal (not
    /// private) for GheenTests. Returns the carried-over runs alongside the
    /// result so the caller can log when this kicks in.
    nonisolated static func reconcile(fresh: [Run]?, lastKnown: [Run]) -> (runs: [Run], carriedOver: [Run]) {
        guard let fresh else { return (lastKnown, lastKnown) }
        let freshKeys = Set(fresh.map { $0.runKey })
        let missing = lastKnown.filter { $0.isActive && !freshKeys.contains($0.runKey) }
        return (fresh + missing, missing)
    }
}
