import SwiftUI

@main
struct ActionsNotifiedApp: App {
    @StateObject private var settings: SettingsStore
    @StateObject private var monitor: Monitor

    init() {
        let settings = SettingsStore()
        let notifier = NotificationManager.shared
        notifier.setup()

        let monitor = Monitor(settings: settings, notifier: notifier)
        _settings = StateObject(wrappedValue: settings)
        _monitor = StateObject(wrappedValue: monitor)

        Task { @MainActor in monitor.start() }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(settings)
                .environmentObject(monitor)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: monitor.iconName)
                    .foregroundStyle(monitor.aggregate == .failure ? Color.red : Color.primary)
                if !monitor.activeRuns.isEmpty {
                    Text("\(monitor.activeRuns.count)")
                        .font(.system(size: 11, weight: .medium))
                }
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(monitor)
        }

        // `-demo` only: the popover content in a normal window, for screenshots.
        Window("Popover preview", id: "preview") {
            MenuContentView()
                .environmentObject(settings)
                .environmentObject(monitor)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(Monitor.demo ? .presented : .suppressed)

        // First run: opens at launch while nothing is watched.
        Window("Welcome to ActionsNotified", id: "welcome") {
            OnboardingView()
                .environmentObject(settings)
                .environmentObject(monitor)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(settings.watchedRepos.isEmpty ? .presented : .suppressed)
    }
}
