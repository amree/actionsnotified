import Foundation
import Combine

/// User-facing settings + small persisted state, backed by UserDefaults.
final class SettingsStore: ObservableObject {
    /// `-demo` keeps its fake repos and settings in a separate domain so a demo
    /// session never overwrites the real ones.
    private let defaults = ProcessInfo.processInfo.arguments.contains("-demo")
        ? UserDefaults(suiteName: "com.amree.actionsnotified.demo")! : .standard

    @Published var watchedRepos: [String] {
        didSet { defaults.set(watchedRepos, forKey: Keys.repos) }
    }
    @Published var pollInterval: Double {
        didSet { defaults.set(pollInterval, forKey: Keys.interval) }
    }
    @Published var ghPath: String {
        didSet { defaults.set(ghPath, forKey: Keys.ghPath) }
    }

    /// "all", "failures" or "never".
    @Published var notifyMode: String {
        didSet { defaults.set(notifyMode, forKey: Keys.notifyMode) }
    }
    /// Which Settings tab is showing; not persisted. Lets the popover's Fix link open Repositories.
    @Published var settingsTab = "general"

    var cachedLogin: String? {
        get { defaults.string(forKey: Keys.login) }
        set { defaults.set(newValue, forKey: Keys.login) }
    }

    /// Runs already notified, keyed by `databaseId#attempt`. Prevents re-notify across launches.
    var notifiedKeys: Set<String> {
        get { Set(defaults.stringArray(forKey: Keys.notified) ?? []) }
        set { defaults.set(Array(newValue), forKey: Keys.notified) }
    }

    private enum Keys {
        static let repos = "watchedRepos"
        static let interval = "pollInterval"
        static let ghPath = "ghPath"
        static let login = "cachedLogin"
        static let notified = "notifiedKeys"
        static let notifyMode = "notifyMode"
    }

    init() {
        // One-time carry-over of settings from the app's old name (Gheen).
        let id = "com.amree.actionsnotified"
        if Bundle.main.bundleIdentifier == id, defaults.persistentDomain(forName: id) == nil,
           let old = defaults.persistentDomain(forName: "com.amree.gheen") {
            defaults.setPersistentDomain(old, forName: id)
        }
        watchedRepos = defaults.stringArray(forKey: Keys.repos) ?? []
        let stored = defaults.double(forKey: Keys.interval)
        pollInterval = stored > 0 ? stored : 30
        ghPath = defaults.string(forKey: Keys.ghPath) ?? ""
        notifyMode = defaults.string(forKey: Keys.notifyMode) ?? "all"
    }
}
