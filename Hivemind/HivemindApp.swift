import SwiftUI

@main
struct HivemindApp: App {
    private let ticker = Ticker()

    var body: some Scene {
        MenuBarExtra("Hivemind", systemImage: "brain") {
            MenuBarView()
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }

    init() {
        _ = NotificationManager.shared

        Task {
            guard WorkspaceSetup.shared.isComplete else {
                await MainActor.run {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                return
            }
            await NotificationManager.shared.requestPermission()
            NotificationManager.shared.applyCurrentSettings()
            await TodayPageManager.shared.ensureToday()
            await WeeklyReviewManager.shared.ensureWeeklyReview()
        }
    }
}

class Ticker {
    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { _ in
            guard WorkspaceSetup.shared.isComplete else { return }
            Task {
                await TodayPageManager.shared.ensureToday()
                await TodayPageManager.shared.refreshSchedule()
                await WeeklyReviewManager.shared.ensureWeeklyReview()
            }
        }
    }
}
