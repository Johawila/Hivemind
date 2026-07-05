import Foundation

struct NoteContext {
    let id: String
    let title: String
    let snippet: String
}

enum ClaudeError: Error {
    case apiError(Int, String)
}

class ClaudeService {
    static let shared = ClaudeService()
    private init() {}

    private let baseURL = "https://api.anthropic.com/v1"
    private let model = "claude-haiku-4-5-20251001"

    // Stored in the shared App Group so Noted can use the same key. Falls back to the
    // legacy standard-defaults value until the one-time migration in HivemindApp runs.
    var apiKey: String {
        let shared = UserDefaults.shared.string(forKey: "hivemind.anthropicApiKey") ?? ""
        return shared.isEmpty ? (UserDefaults.standard.string(forKey: "hivemind.anthropicApiKey") ?? "") : shared
    }

    struct LinkSuggestion: Decodable {
        let noteId: String
        let confidence: Double
        let reason: String
    }

    func suggestLinks(for note: NoteContext, against others: [NoteContext]) async throws -> [LinkSuggestion] {
        guard !apiKey.isEmpty, !others.isEmpty else { return [] }

        let othersText = others
            .map { "ID: \($0.id)\nTitle: \($0.title)\nSnippet: \($0.snippet)" }
            .joined(separator: "\n\n---\n\n")

        let userMessage = """
        New note to find connections for:
        Title: \(note.title)
        Content: \(note.snippet)

        Existing notes:
        \(othersText)
        """

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "system": systemPrompt,
            "messages": [["role": "user", "content": userMessage]]
        ]

        var request = URLRequest(url: URL(string: "\(baseURL)/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ClaudeError.apiError(http.statusCode, message)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let content = (json?["content"] as? [[String: Any]])?.first,
              let text = content["text"] as? String,
              let jsonStart = text.firstIndex(of: "["),
              let jsonEnd = text.lastIndex(of: "]") else { return [] }

        let jsonString = String(text[jsonStart...jsonEnd])
        return (try? JSONDecoder().decode([LinkSuggestion].self, from: Data(jsonString.utf8))) ?? []
    }

    // MARK: - Weekly Review

    struct WeeklyReviewContent: Decodable {
        let overview: String
        let wins: [String]
        let blockers: [String]
        let nextWeekFocus: String
    }

    func generateWeeklyReview(days: [WeeklyDayData], previousFocus: String?) async throws -> WeeklyReviewContent {
        guard !apiKey.isEmpty else { throw ClaudeError.apiError(0, "No API key") }

        let daysText = days.map { day in
            var parts = ["\(day.displayDate):"]
            parts.append("  MIT: \"\(day.mit)\" — \(day.mitCompleted ? "✓ completed" : "not completed")")
            if !day.meetings.isEmpty {
                parts.append("  Meetings: \(day.meetings.joined(separator: " | "))")
            } else {
                parts.append("  Meetings: none")
            }
            if !day.completedTasks.isEmpty {
                parts.append("  Completed tasks: \(day.completedTasks.joined(separator: ", "))")
            }
            if !day.reflectionAnswer.isEmpty {
                parts.append("  Reflection (\(day.reflectionQuestion)): \(day.reflectionAnswer)")
            } else if !day.reflectionQuestion.isEmpty {
                parts.append("  Reflection (\(day.reflectionQuestion)): [no answer]")
            }
            return parts.joined(separator: "\n")
        }.joined(separator: "\n\n")

        var userMessage = "Here is last week's daily note data:\n\n\(daysText)"
        if let focus = previousFocus {
            userMessage += "\n\nThe focus set for this week at the end of last week's review was:\n\"\(focus)\""
        }

        let body: [String: Any] = [
            "model": "claude-sonnet-4-6",
            "max_tokens": 1500,
            "system": weeklyReviewSystemPrompt,
            "messages": [["role": "user", "content": userMessage]]
        ]

        var request = URLRequest(url: URL(string: "\(baseURL)/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw ClaudeError.apiError(http.statusCode, message)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let content = (json?["content"] as? [[String: Any]])?.first,
              let text = content["text"] as? String,
              let jsonStart = text.firstIndex(of: "{"),
              let jsonEnd = text.lastIndex(of: "}") else {
            throw ClaudeError.apiError(0, "Invalid response format")
        }

        let jsonString = String(text[jsonStart...jsonEnd])
        return try JSONDecoder().decode(WeeklyReviewContent.self, from: Data(jsonString.utf8))
    }

    private let weeklyReviewSystemPrompt = """
    You are a strategic weekly review assistant for an engineering manager on a deliberate path to becoming a CTO. You receive a week's daily note data — including meetings, MITs, completed tasks, and reflections — and write a concise, honest review that surfaces patterns relevant to leadership growth.

    Respond ONLY with a JSON object in this exact format:
    {
      "overview": "2-3 sentences summarising the week's theme, leadership moments, and overall energy",
      "wins": ["specific win 1", "specific win 2", "specific win 3"],
      "blockers": ["specific blocker 1", "specific blocker 2"],
      "nextWeekFocus": "One specific, actionable suggested focus for next week that moves the needle on becoming a stronger technical leader"
    }

    Rules:
    - Be direct and specific — reference actual MITs, tasks, meetings, and reflections from the data
    - Do not be generic or motivational
    - wins and blockers should be arrays of 2-4 short strings each
    - When wins represent leadership actions (decisions made, clarity given, people unblocked, systems improved), call that out explicitly
    - When blockers are self-imposed (avoidance, unclear priorities, reactive mode), name that pattern directly
    - nextWeekFocus should reflect the EM → CTO trajectory: strategic thinking, technical vision, team capability, stakeholder alignment, or own learning
    - If a day has no data, acknowledge the gap but don't dwell on it
    - Treat reflections seriously — they often reveal the real blockers behind the surface ones
    - Analyse the meeting schedule: flag days where back-to-back meetings left no focus time, double-bookings or overlapping meeting slots, and whether meeting-heavy days correlated with missed MITs or low output
    - If the meeting load looks high relative to deep work time, call that out as a structural blocker
    - If a previous week's focus is provided, explicitly assess whether it was acted upon. If yes, count it as a win. If not, name why it slipped and decide whether it should carry forward into nextWeekFocus or be dropped in favour of a higher priority
    """

    private let systemPrompt = """
    You are a knowledge graph assistant for a Zettelkasten-style note system. Given a new note and a list of existing notes, identify which existing notes are conceptually related to the new note.

    For each meaningful connection provide:
    - noteId: the ID of the related note
    - confidence: a score from 0.0 to 1.0
    - reason: one sentence explaining the conceptual connection

    Confidence guidelines:
    - 0.8–1.0: Strong conceptual overlap, clearly related ideas
    - 0.5–0.8: Meaningful but uncertain connection, worth reviewing
    - Below 0.5: Do not include

    Respond ONLY with a valid JSON array. No text outside the JSON.
    Example: [{"noteId": "abc123", "confidence": 0.85, "reason": "Both discuss managing priorities under pressure."}]
    If no meaningful connections exist, respond with: []
    """
}
