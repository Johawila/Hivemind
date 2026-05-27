import Foundation
import Combine

struct PendingLink: Codable, Identifiable {
    let id: UUID
    let noteAId: String
    let noteATitle: String
    let noteASnippet: String
    let noteBId: String
    let noteBTitle: String
    let noteBSnippet: String
    let confidence: Double
    let reason: String
}

class LinkingManager: ObservableObject {
    static let shared = LinkingManager()

    private init() {
        loadPendingLinks()
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.hivemind.noteAdded"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.checkForNewNotes() }
        }
    }

    @Published var pendingLinks: [PendingLink] = []

    private let notion = NotionService.shared
    private let claude = ClaudeService.shared
    private var notesDbId: String { UserDefaults.shared.string(forKey: "hivemind.notesDbId") ?? "" }

    // MARK: - Public

    func checkForNewNotes(onDemand: Bool = false) async {
        guard !notesDbId.isEmpty else {
            if onDemand { NotificationManager.shared.send(title: "⚠️ Notes DB not set up", body: "Run Setup in Settings first") }
            return
        }

        let lastScan = UserDefaults.standard.object(forKey: "hivemind.lastNoteScanDate") as? Date ?? Date.distantPast
        let isoString = ISO8601DateFormatter().string(from: lastScan)

        let filter: [String: Any] = [
            "timestamp": "created_time",
            "created_time": ["after": isoString]
        ]

        guard let newNotes = try? await notion.queryDatabase(databaseId: notesDbId, filter: filter),
              !newNotes.isEmpty else {
            if onDemand { NotificationManager.shared.send(title: "🔍 No new notes found", body: "Nothing added since last scan") }
            return
        }

        UserDefaults.standard.set(Date(), forKey: "hivemind.lastNoteScanDate")

        guard let allNotes = try? await notion.queryDatabase(databaseId: notesDbId) else { return }

        for note in newNotes {
            await scanNote(note, against: allNotes)
        }
    }

    func approveLink(_ link: PendingLink) async {
        await addNotionRelation(noteAId: link.noteAId, noteBId: link.noteBId)
        await MainActor.run { removePendingLink(id: link.id) }
    }

    func dismissLink(_ link: PendingLink) {
        removePendingLink(id: link.id)
    }

    func loadTestData() {
        pendingLinks = [
            PendingLink(
                id: UUID(),
                noteAId: "test-a-1",
                noteATitle: "Prioritisation under pressure",
                noteASnippet: "When everything feels urgent, the key is to identify what actually moves the needle...",
                noteBId: "test-b-1",
                noteBTitle: "Eisenhower Matrix",
                noteBSnippet: "A framework for sorting tasks by urgency and importance into four quadrants...",
                confidence: 0.72,
                reason: "Both discuss managing competing priorities under time pressure."
            ),
            PendingLink(
                id: UUID(),
                noteAId: "test-a-2",
                noteATitle: "Deep work requires protecting time",
                noteASnippet: "Focused work sessions without interruption produce disproportionately better results...",
                noteBId: "test-b-2",
                noteBTitle: "Calendar blocking strategy",
                noteBSnippet: "Assigning every hour a specific job prevents reactive work from filling the day...",
                confidence: 0.65,
                reason: "Both address the importance of intentionally structuring time for focused work."
            ),
            PendingLink(
                id: UUID(),
                noteAId: "test-a-3",
                noteATitle: "Second brain concept",
                noteASnippet: "Offloading information to an external system frees cognitive capacity for higher thinking...",
                noteBId: "test-b-3",
                noteBTitle: "Zettelkasten method",
                noteBSnippet: "Atomic linked notes build a web of ideas that surfaces unexpected connections over time...",
                confidence: 0.58,
                reason: "Both explore using external systems to augment thinking and knowledge retention."
            )
        ]
        savePendingLinks()
    }

    // MARK: - Private

    private func scanNote(_ note: [String: Any], against allNotes: [[String: Any]]) async {
        guard let noteId = note["id"] as? String else { return }
        let title = extractTitle(from: note)
        let content = extractContent(from: note)

        let noteContext = NoteContext(id: noteId, title: title, snippet: String(content.prefix(300)))
        let others = allNotes.compactMap { other -> NoteContext? in
            guard let otherId = other["id"] as? String, otherId != noteId else { return nil }
            return NoteContext(
                id: otherId,
                title: extractTitle(from: other),
                snippet: String(extractContent(from: other).prefix(200))
            )
        }

        guard !others.isEmpty else {
            NotificationManager.shared.send(title: "🔍 No connections found yet", body: "\"\(title)\"")
            return
        }

        guard let suggestions = try? await claude.suggestLinks(for: noteContext, against: others),
              !suggestions.isEmpty else {
            NotificationManager.shared.send(title: "🔍 No connections found yet", body: "\"\(title)\"")
            return
        }

        let confirmed = suggestions.filter { $0.confidence >= 0.8 }
        let pending = suggestions.filter { $0.confidence >= 0.5 && $0.confidence < 0.8 }

        for suggestion in confirmed {
            await addNotionRelation(noteAId: noteId, noteBId: suggestion.noteId)
        }

        for suggestion in pending {
            guard let match = allNotes.first(where: { ($0["id"] as? String) == suggestion.noteId }) else { continue }
            let link = PendingLink(
                id: UUID(),
                noteAId: noteId,
                noteATitle: title,
                noteASnippet: String(content.prefix(120)),
                noteBId: suggestion.noteId,
                noteBTitle: extractTitle(from: match),
                noteBSnippet: String(extractContent(from: match).prefix(120)),
                confidence: suggestion.confidence,
                reason: suggestion.reason
            )
            await MainActor.run { pendingLinks.append(link) }
        }
        savePendingLinks()

        sendLinkNotification(noteTitle: title, confirmed: confirmed.count, pending: pending.count)
    }

    private func addNotionRelation(noteAId: String, noteBId: String) async {
        guard let page = try? await notion.fetchPage(pageId: noteAId),
              let props = page["properties"] as? [String: Any],
              let linksProp = props["Links"] as? [String: Any],
              let existing = linksProp["relation"] as? [[String: Any]] else {
            try? await notion.updatePage(pageId: noteAId, properties: [
                "Links": ["relation": [["id": noteBId]]]
            ])
            return
        }

        guard !existing.contains(where: { $0["id"] as? String == noteBId }) else { return }
        var updated = existing
        updated.append(["id": noteBId])
        try? await notion.updatePage(pageId: noteAId, properties: [
            "Links": ["relation": updated]
        ])
    }

    private func sendLinkNotification(noteTitle: String, confirmed: Int, pending: Int) {
        if confirmed == 0 && pending == 0 {
            NotificationManager.shared.send(title: "🔍 No connections found yet", body: "\"\(noteTitle)\"")
            return
        }
        var parts: [String] = []
        if confirmed > 0 { parts.append("\(confirmed) confirmed") }
        if pending > 0 { parts.append("\(pending) pending review") }
        NotificationManager.shared.send(title: "🔗 \(parts.joined(separator: ", "))", body: "\"\(noteTitle)\"")
    }

    private func removePendingLink(id: UUID) {
        pendingLinks.removeAll { $0.id == id }
        savePendingLinks()
    }

    private func savePendingLinks() {
        if let data = try? JSONEncoder().encode(pendingLinks) {
            UserDefaults.standard.set(data, forKey: "hivemind.pendingLinks")
        }
    }

    private func loadPendingLinks() {
        guard let data = UserDefaults.standard.data(forKey: "hivemind.pendingLinks"),
              let links = try? JSONDecoder().decode([PendingLink].self, from: data) else { return }
        pendingLinks = links
    }

    private func extractTitle(from note: [String: Any]) -> String {
        let props = note["properties"] as? [String: Any]
        return ((props?["Name"] as? [String: Any])?["title"] as? [[String: Any]])?.first?["plain_text"] as? String ?? "Untitled"
    }

    private func extractContent(from note: [String: Any]) -> String {
        let props = note["properties"] as? [String: Any]
        guard let contentProp = props?["Content"] as? [String: Any],
              let richText = contentProp["rich_text"] as? [[String: Any]] else { return "" }
        return richText.compactMap { $0["plain_text"] as? String }.joined()
    }
}
