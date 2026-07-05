import Foundation
import Combine

class WorkspaceSetup: ObservableObject {
    static let shared = WorkspaceSetup()
    private init() {}

    @Published var isRunning = false
    @Published var statusMessage = ""

    var isComplete: Bool {
        !projectsDbId.isEmpty && !peopleDbId.isEmpty && !teamsDbId.isEmpty &&
        !scheduleDbId.isEmpty && !archivePageId.isEmpty && !tasksDbId.isEmpty &&
        !(UserDefaults.shared.string(forKey: "notionApiKey") ?? "").isEmpty &&
        !(UserDefaults.shared.string(forKey: "notionParentPageId") ?? "").isEmpty
    }

    private let notion = NotionService.shared

    var projectsDbId: String {
        get { UserDefaults.shared.string(forKey: "hivemind.projectsDbId") ?? "" }
        set { objectWillChange.send(); UserDefaults.shared.set(newValue, forKey: "hivemind.projectsDbId") }
    }
    var peopleDbId: String {
        get { UserDefaults.shared.string(forKey: "hivemind.peopleDbId") ?? "" }
        set { objectWillChange.send(); UserDefaults.shared.set(newValue, forKey: "hivemind.peopleDbId") }
    }
    var teamsDbId: String {
        get { UserDefaults.shared.string(forKey: "hivemind.teamsDbId") ?? "" }
        set { objectWillChange.send(); UserDefaults.shared.set(newValue, forKey: "hivemind.teamsDbId") }
    }
    var scheduleDbId: String {
        get { UserDefaults.shared.string(forKey: "hivemind.scheduleDbId") ?? "" }
        set { objectWillChange.send(); UserDefaults.shared.set(newValue, forKey: "hivemind.scheduleDbId") }
    }
    var archivePageId: String {
        get { UserDefaults.shared.string(forKey: "hivemind.archivePageId") ?? "" }
        set { objectWillChange.send(); UserDefaults.shared.set(newValue, forKey: "hivemind.archivePageId") }
    }
    var tasksDbId: String {
        get { UserDefaults.shared.string(forKey: "hivemind.tasksDbId") ?? "" }
        set { objectWillChange.send(); UserDefaults.shared.set(newValue, forKey: "hivemind.tasksDbId") }
    }
    var notesDbId: String {
        get { UserDefaults.shared.string(forKey: "hivemind.notesDbId") ?? "" }
        set { objectWillChange.send(); UserDefaults.shared.set(newValue, forKey: "hivemind.notesDbId") }
    }
    var weeklySummariesPageId: String {
        get { UserDefaults.shared.string(forKey: "hivemind.weeklySummariesPageId") ?? "" }
        set { objectWillChange.send(); UserDefaults.shared.set(newValue, forKey: "hivemind.weeklySummariesPageId") }
    }
    var articlesDbId: String {
        get { UserDefaults.shared.string(forKey: "hivemind.articlesDbId") ?? "" }
        set { objectWillChange.send(); UserDefaults.shared.set(newValue, forKey: "hivemind.articlesDbId") }
    }
    var conceptsDbId: String {
        get { UserDefaults.shared.string(forKey: "hivemind.conceptsDbId") ?? "" }
        set { objectWillChange.send(); UserDefaults.shared.set(newValue, forKey: "hivemind.conceptsDbId") }
    }
    var knowledgeMapPageId: String {
        get { UserDefaults.shared.string(forKey: "hivemind.knowledgeMapPageId") ?? "" }
        set { objectWillChange.send(); UserDefaults.shared.set(newValue, forKey: "hivemind.knowledgeMapPageId") }
    }

    // MARK: - Public

    func run(apiKey: String, parentPageId: String) async throws {
        update(running: true, "Setting up workspace…")

        do {
            guard !apiKey.isEmpty else { throw NotionError.notConfigured }
            guard !parentPageId.isEmpty else { throw NotionError.missingField("Hivemind Page ID") }

            UserDefaults.shared.set(apiKey, forKey: "notionApiKey")
            UserDefaults.shared.set(parentPageId, forKey: "notionParentPageId")

            update("Checking Teams database…")
            if let existing = try await notion.findChildDatabase(parentPageId: parentPageId, title: "Teams") {
                teamsDbId = existing
                try? await notion.updateIcon(id: existing, emoji: "🏢", isDatabase: true)
            } else {
                update("Creating Teams database…")
                teamsDbId = try await notion.createDatabase(
                    parentPageId: parentPageId, title: "Teams", icon: "🏢",
                    properties: [
                        "Name": ["title": [:]],
                        "Description": ["rich_text": [:]]
                    ]
                )
            }

            update("Checking Projects database…")
            if let existing = try await notion.findChildDatabase(parentPageId: parentPageId, title: "Projects") {
                projectsDbId = existing
                try? await notion.updateIcon(id: existing, emoji: "📁", isDatabase: true)
                try? await notion.updateDatabaseProperties(databaseId: existing, properties: colorProperty())
            } else {
                update("Creating Projects database…")
                var props: [String: Any] = [
                    "Name": ["title": [:]],
                    "Status": ["select": ["options": [
                        ["name": "Active", "color": "green"],
                        ["name": "On Hold", "color": "yellow"],
                        ["name": "Completed", "color": "gray"]
                    ]]],
                    "Description": ["rich_text": [:]]
                ]
                props.merge(colorProperty()) { _, new in new }
                projectsDbId = try await notion.createDatabase(
                    parentPageId: parentPageId, title: "Projects", icon: "📁", properties: props
                )
            }

            update("Checking People database…")
            if let existing = try await notion.findChildDatabase(parentPageId: parentPageId, title: "People") {
                peopleDbId = existing
                try? await notion.updateIcon(id: existing, emoji: "👥", isDatabase: true)
            } else {
                update("Creating People database…")
                var props: [String: Any] = [
                    "Name": ["title": [:]],
                    "Role": ["rich_text": [:]],
                    "Team": ["relation": ["database_id": teamsDbId, "type": "single_property", "single_property": [:]] as [String: Any]]
                ]
                props.merge(colorProperty()) { _, new in new }
                peopleDbId = try await notion.createDatabase(
                    parentPageId: parentPageId, title: "People", icon: "👥", properties: props
                )
            }

            update("Checking Tasks database…")
            if let existing = try await notion.findChildDatabase(parentPageId: parentPageId, title: "Tasks") {
                tasksDbId = existing
                try? await notion.updateIcon(id: existing, emoji: "✅", isDatabase: true)
                // Recreate Person relation to ensure it points to the correct People database
                try? await notion.updateDatabaseProperties(databaseId: existing, properties: ["Person": NSNull()])
                try await notion.updateDatabaseProperties(databaseId: existing, properties: [
                    "Person": ["relation": ["database_id": peopleDbId, "type": "single_property", "single_property": [:]] as [String: Any]]
                ])
            } else {
                update("Creating Tasks database…")
                let props: [String: Any] = [
                    "Name": ["title": [:]],
                    "Date": ["date": [:]],
                    "Done": ["checkbox": [:]],
                    "Project": ["relation": ["database_id": projectsDbId, "type": "single_property", "single_property": [:]] as [String: Any]],
                    "Person": ["relation": ["database_id": peopleDbId, "type": "single_property", "single_property": [:]] as [String: Any]]
                ]
                tasksDbId = try await notion.createDatabase(
                    parentPageId: parentPageId, title: "Tasks", icon: "✅", properties: props
                )
            }

            update("Checking Schedule database…")
            if let existing = try await notion.findChildDatabase(parentPageId: parentPageId, title: "Schedule") {
                scheduleDbId = existing
                try? await notion.updateIcon(id: existing, emoji: "📅", isDatabase: true)
            } else {
                update("Creating Schedule database…")
                scheduleDbId = try await notion.createDatabase(
                    parentPageId: parentPageId, title: "Schedule", icon: "📅",
                    properties: [
                        "Name": ["title": [:]],
                        "Date": ["date": [:]]
                    ]
                )
            }

            update("Checking Notes database…")
            if let existing = try await notion.findChildDatabase(parentPageId: parentPageId, title: "Notes") {
                notesDbId = existing
                try? await notion.updateIcon(id: existing, emoji: "📒", isDatabase: true)
                // Add Project/Person relations if not already present (idempotent — Notion updates if already exists)
                try await notion.updateDatabaseProperties(databaseId: existing, properties: notesRelationProperties(projectsDbId: projectsDbId, peopleDbId: peopleDbId))
            } else {
                update("Creating Notes database…")
                let newId = try await notion.createDatabase(
                    parentPageId: parentPageId, title: "Notes", icon: "📒",
                    properties: [
                        "Name": ["title": [:]],
                        "Content": ["rich_text": [:]],
                        "Tags": ["multi_select": [:]],
                        "Created": ["created_time": [:]]
                    ]
                )
                notesDbId = newId
                // Patch relations after creation (Notion requires the DB to exist first)
                var relationPatches = notesRelationProperties(projectsDbId: projectsDbId, peopleDbId: peopleDbId)
                relationPatches["Links"] = ["relation": [
                    "database_id": newId,
                    "type": "dual_property",
                    "dual_property": [:]
                ] as [String: Any]] as [String: Any]
                try await notion.updateDatabaseProperties(databaseId: newId, properties: relationPatches)
            }

            try await setupArticlesAndConcepts(parentPageId: parentPageId)

            update("Checking Weekly Summaries page…")
            if let existing = try await notion.findChildPage(parentPageId: parentPageId, title: "Weekly Summaries") {
                weeklySummariesPageId = existing
                try? await notion.updateIcon(id: existing, emoji: "📋")
            } else {
                update("Creating Weekly Summaries page…")
                weeklySummariesPageId = try await notion.createPage(parentPageId: parentPageId, title: "Weekly Summaries", icon: "📋")
            }

            update("Checking Archive page…")
            if let existing = try await notion.findChildPage(parentPageId: parentPageId, title: "Archive") {
                archivePageId = existing
                try? await notion.updateIcon(id: existing, emoji: "🗃️")
            } else {
                update("Creating Archive page…")
                archivePageId = try await notion.createPage(parentPageId: parentPageId, title: "Archive", icon: "🗃️")
            }

            update(running: false, "Workspace ready.")
        } catch {
            update(running: false, error.localizedDescription)
            throw error
        }
    }

    // MARK: - Private

    // Creates the Concepts + Articles databases used by Noted's article ingestion,
    // then links them: Articles → Concepts (dual relation) and Concepts → Concepts (related).
    private func setupArticlesAndConcepts(parentPageId: String) async throws {
        update("Checking Concepts database…")
        if let existing = try await notion.findChildDatabase(parentPageId: parentPageId, title: "Concepts") {
            conceptsDbId = existing
            try? await notion.updateIcon(id: existing, emoji: "🧩", isDatabase: true)
        } else {
            update("Creating Concepts database…")
            conceptsDbId = try await notion.createDatabase(
                parentPageId: parentPageId, title: "Concepts", icon: "🧩",
                properties: [
                    "Name": ["title": [:]],
                    "Summary": ["rich_text": [:]],
                    "Topics": ["multi_select": [:]]
                ]
            )
        }

        update("Checking Articles database…")
        if let existing = try await notion.findChildDatabase(parentPageId: parentPageId, title: "Articles") {
            articlesDbId = existing
            try? await notion.updateIcon(id: existing, emoji: "📚", isDatabase: true)
        } else {
            update("Creating Articles database…")
            articlesDbId = try await notion.createDatabase(
                parentPageId: parentPageId, title: "Articles", icon: "📚",
                properties: [
                    "Name": ["title": [:]],
                    "URL": ["url": [:]],
                    "Source": ["rich_text": [:]],
                    "Author": ["rich_text": [:]],
                    "Published": ["date": [:]],
                    "Saved": ["date": [:]],
                    "Read Time": ["number": [:]],
                    "Progress": ["number": ["format": "percent"]],
                    "Topics": ["multi_select": [:]],
                    "Status": ["select": ["options": [
                        ["name": "Processing", "color": "yellow"],
                        ["name": "Ready", "color": "green"],
                        ["name": "Failed", "color": "red"]
                    ]]]
                ]
            )
        }

        // Ensure the Progress bar property exists on pre-existing Articles DBs too (idempotent).
        try await notion.updateDatabaseProperties(databaseId: articlesDbId, properties: [
            "Progress": ["number": ["format": "percent"]]
        ])

        // Relations are patched after both databases exist (Notion requires the targets first).
        update("Linking Articles ↔ Concepts…")
        try await notion.updateDatabaseProperties(databaseId: articlesDbId, properties: [
            "Concepts": ["relation": [
                "database_id": conceptsDbId, "type": "dual_property", "dual_property": [:]
            ] as [String: Any]] as [String: Any]
        ])
        try await notion.updateDatabaseProperties(databaseId: conceptsDbId, properties: [
            "Related": ["relation": [
                "database_id": conceptsDbId, "type": "dual_property", "dual_property": [:]
            ] as [String: Any]] as [String: Any]
        ])

        // Ensure the Topics property exists on pre-existing Concepts DBs too (idempotent).
        try await notion.updateDatabaseProperties(databaseId: conceptsDbId, properties: [
            "Topics": ["multi_select": [:]]
        ])

        update("Checking Knowledge Map page…")
        if let existing = try await notion.findChildPage(parentPageId: parentPageId, title: "Knowledge Map") {
            knowledgeMapPageId = existing
            try? await notion.updateIcon(id: existing, emoji: "🗺️")
        } else {
            update("Creating Knowledge Map page…")
            knowledgeMapPageId = try await notion.createPage(parentPageId: parentPageId, title: "Knowledge Map", icon: "🗺️")
        }
    }

private func notesRelationProperties(projectsDbId: String, peopleDbId: String) -> [String: Any] {
        var props: [String: Any] = [:]
        if !projectsDbId.isEmpty {
            props["Project"] = ["relation": ["database_id": projectsDbId, "type": "single_property", "single_property": [:]] as [String: Any]] as [String: Any]
        }
        if !peopleDbId.isEmpty {
            props["Person"] = ["relation": ["database_id": peopleDbId, "type": "single_property", "single_property": [:]] as [String: Any]] as [String: Any]
        }
        return props
    }

    private func colorProperty() -> [String: Any] {
        let options: [[String: Any]] = ["red", "orange", "yellow", "green", "blue", "purple", "pink", "gray"].map {
            ["name": $0, "color": $0]
        }
        return ["Color": ["select": ["options": options] as [String: Any]] as [String: Any]]
    }

    @MainActor
    private func update(running: Bool? = nil, _ message: String = "") {
        if let running { isRunning = running }
        if !message.isEmpty { statusMessage = message }
    }
}
