import SwiftUI

struct SettingsView: View {
    @AppStorage("notionApiKey", store: .shared) private var apiKey = ""
    @AppStorage("notionParentPageId", store: .shared) private var parentPageId = "333cdd839d1580b49f3ce9bb3ac26520"
    @AppStorage("hivemind.calendarUrl") private var calendarUrl = ""
    @ObservedObject private var setup = WorkspaceSetup.shared
    @State private var regeneratingWeekly = false

    @AppStorage("hivemind.anthropicApiKey") private var anthropicApiKey = ""

    @AppStorage("hivemind.morningNudgeEnabled") private var morningEnabled = false
    @AppStorage("hivemind.eveningNudgeEnabled") private var eveningEnabled = false
    @AppStorage("hivemind.morningNudgeSeconds") private var morningSeconds: Double = 8 * 3600 + 30 * 60
    @AppStorage("hivemind.eveningNudgeSeconds") private var eveningSeconds: Double = 16 * 3600 + 30 * 60

    private var morningTime: Binding<Date> {
        Binding(
            get: { Calendar.current.startOfDay(for: Date()).addingTimeInterval(morningSeconds) },
            set: { morningSeconds = $0.timeIntervalSince(Calendar.current.startOfDay(for: $0)) }
        )
    }

    private var eveningTime: Binding<Date> {
        Binding(
            get: { Calendar.current.startOfDay(for: Date()).addingTimeInterval(eveningSeconds) },
            set: { eveningSeconds = $0.timeIntervalSince(Calendar.current.startOfDay(for: $0)) }
        )
    }

    var body: some View {
        Form {
            Section("Notion") {
                SecureField("API Key", text: $apiKey)
                HStack {
                    TextField("Hivemind Page ID", text: $parentPageId)
                    if setup.isComplete {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            }

            Section("Calendar") {
                TextField("Outlook ICS URL (webcal:// or https://)", text: $calendarUrl)
            }

            Section("AI Linking") {
                SecureField("Anthropic API Key", text: $anthropicApiKey)
            }

            Section("Notifications") {
                Toggle("Morning nudge", isOn: $morningEnabled)
                    .onChange(of: morningEnabled) { enabled in
                        if enabled { Task { await NotificationManager.shared.requestPermission() } }
                        NotificationManager.shared.applyCurrentSettings()
                    }
                if morningEnabled {
                    DatePicker("Time", selection: morningTime, displayedComponents: .hourAndMinute)
                        .onChange(of: morningSeconds) { _ in
                            NotificationManager.shared.applyCurrentSettings()
                        }
                }

                Toggle("Evening nudge", isOn: $eveningEnabled)
                    .onChange(of: eveningEnabled) { enabled in
                        if enabled { Task { await NotificationManager.shared.requestPermission() } }
                        NotificationManager.shared.applyCurrentSettings()
                    }
                if eveningEnabled {
                    DatePicker("Time", selection: eveningTime, displayedComponents: .hourAndMinute)
                        .onChange(of: eveningSeconds) { _ in
                            NotificationManager.shared.applyCurrentSettings()
                        }
                }
            }

            Section("Workspace") {
                if setup.isRunning {
                    HStack {
                        ProgressView().scaleEffect(0.7)
                        Text(setup.statusMessage).foregroundStyle(.secondary)
                    }
                } else if !setup.statusMessage.isEmpty {
                    Text(setup.statusMessage)
                        .foregroundStyle(setup.isComplete ? .green : .red)
                }

                Button("Run Setup") {
                    Task { try? await setup.run(apiKey: apiKey, parentPageId: parentPageId) }
                }
                .disabled(setup.isRunning || apiKey.isEmpty)

                Button("Force Create Today's Page") {
                    Task { await TodayPageManager.shared.forceCreateToday() }
                }
                .disabled(!setup.isComplete)

                HStack {
                    Button(regeneratingWeekly ? "Regenerating…" : "Regenerate Last Week's Summary") {
                        regeneratingWeekly = true
                        Task {
                            await WeeklyReviewManager.shared.regenerateWeeklyReview(weeksAgo: 1)
                            regeneratingWeekly = false
                        }
                    }
                    .disabled(regeneratingWeekly || !setup.isComplete)
                    if regeneratingWeekly { ProgressView().scaleEffect(0.7) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding(.bottom)
    }
}
