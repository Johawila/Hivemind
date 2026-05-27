import Foundation

struct WeeklyDayData {
    let displayDate: String
    let mit: String
    let mitCompleted: Bool
    let reflectionQuestion: String
    let reflectionAnswer: String
    let completedTasks: [String]
    let meetings: [String]
}

class WeeklyReviewManager {
    static let shared = WeeklyReviewManager()
    private init() {}

    private let notion = NotionService.shared
    private let claude = ClaudeService.shared

    private var weeklySummariesPageId: String { UserDefaults.shared.string(forKey: "hivemind.weeklySummariesPageId") ?? "" }

    // MARK: - Public

    func ensureWeeklyReview() async {
        guard isMonday, !weeklySummariesPageId.isEmpty else { return }

        let weekKey = currentWeekKey()
        let lastKey = UserDefaults.standard.string(forKey: "hivemind.lastWeeklyReviewKey") ?? ""
        guard lastKey != weekKey else { return }

        let days = await fetchWeekData(weeksAgo: 1)
        guard !days.isEmpty else { return }

        let previousFocus = await fetchPreviousWeekFocus()
        guard let summary = try? await claude.generateWeeklyReview(days: days, previousFocus: previousFocus) else { return }

        let title = weekPageTitle(weeksAgo: 1)
        guard let pageId = try? await createWeeklyPage(title: title, summary: summary) else { return }

        UserDefaults.standard.set(pageId, forKey: "hivemind.lastWeeklyReviewPageId")
        UserDefaults.standard.set(weekKey, forKey: "hivemind.lastWeeklyReviewKey")
        NotificationManager.shared.send(title: "📋 Weekly review is ready", body: title)
    }

    func regenerateWeeklyReview(weeksAgo: Int = 1) async {
        guard !weeklySummariesPageId.isEmpty else { return }

        let days = await fetchWeekData(weeksAgo: weeksAgo)
        guard !days.isEmpty else { return }

        guard let summary = try? await claude.generateWeeklyReview(days: days, previousFocus: nil) else { return }

        let title = weekPageTitle(weeksAgo: weeksAgo) + " (regenerated)"
        guard (try? await createWeeklyPage(title: title, summary: summary)) != nil else { return }

        NotificationManager.shared.send(title: "📋 Weekly review regenerated", body: title)
    }

    // MARK: - Private

    private func fetchWeekData(weeksAgo: Int) async -> [WeeklyDayData] {
        let cal = Calendar(identifier: .gregorian)
        let lastMonday = mondayOfWeeksAgo(weeksAgo)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"

        let displayFormatter = DateFormatter()
        displayFormatter.dateFormat = "EEEE, MMMM d"

        let allEvents = await fetchWeekEvents(monday: lastMonday)

        var days: [WeeklyDayData] = []

        for offset in 0..<5 {
            guard let date = cal.date(byAdding: .day, value: offset, to: lastMonday) else { continue }
            let dateString = dateFormatter.string(from: date)

            guard let pageId = UserDefaults.shared.string(forKey: "hivemind.pageId.\(dateString)"),
                  !pageId.isEmpty else { continue }

            let dayStart = cal.startOfDay(for: date)
            let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart)!
            let filtered = allEvents.filter { !$0.isAllDay && $0.startDate >= dayStart && $0.startDate < dayEnd }
            let sorted = filtered.sorted { $0.startDate < $1.startDate }
            let dayMeetings = sorted.map { "\($0.timeString)  \($0.summary)" }

            let displayDate = displayFormatter.string(from: date)
            if let dayData = await extractDayData(pageId: pageId, displayDate: displayDate, meetings: dayMeetings) {
                days.append(dayData)
            }
        }

        return days
    }

    private func fetchPreviousWeekFocus() async -> String? {
        guard let pageId = UserDefaults.standard.string(forKey: "hivemind.lastWeeklyReviewPageId"),
              !pageId.isEmpty else { return nil }
        guard let blocks = try? await notion.fetchBlockChildren(blockId: pageId) else { return nil }

        var nextIsFocus = false
        for block in blocks {
            let type = block["type"] as? String ?? ""
            if type == "heading_2" {
                let text = NotionService.plainText(from: (block["heading_2"] as? [String: Any])?["rich_text"])
                nextIsFocus = text == "Focus for next week"
            } else if nextIsFocus, type == "paragraph" {
                let text = NotionService.plainText(from: (block["paragraph"] as? [String: Any])?["rich_text"])
                if !text.isEmpty { return text }
            } else if nextIsFocus {
                nextIsFocus = false
            }
        }
        return nil
    }

    private func fetchWeekEvents(monday: Date) async -> [ICSEvent] {
        let urlString = UserDefaults.standard.string(forKey: "hivemind.calendarUrl") ?? ""
        guard !urlString.isEmpty else { return [] }
        return (try? await ICSParser.fetchAndParse(urlString: urlString)) ?? []
    }

    private func extractDayData(pageId: String, displayDate: String, meetings: [String]) async -> WeeklyDayData? {
        guard let blocks = try? await notion.fetchBlockChildren(blockId: pageId) else { return nil }

        var mit = ""
        var mitCompleted = false
        var reflectionQuestion = ""
        var reflectionAnswer = ""
        var completedTasks: [String] = []
        var inTasks = false
        var afterReflection = false

        for block in blocks {
            let type = block["type"] as? String ?? ""

            // Capture page-level paragraphs immediately after the reflection callout
            if afterReflection {
                if type == "paragraph" {
                    let text = NotionService.plainText(from: (block["paragraph"] as? [String: Any])?["rich_text"])
                    if !text.isEmpty {
                        reflectionAnswer = reflectionAnswer.isEmpty ? text : reflectionAnswer + " " + text
                        continue
                    }
                }
                afterReflection = false
            }

            // MIT lives inside column_list > column > "Today's Focus" callout
            if type == "column_list" {
                guard mit.isEmpty, let colListId = block["id"] as? String,
                      let cols = try? await notion.fetchBlockChildren(blockId: colListId) else { continue }
                for col in cols {
                    guard let colId = col["id"] as? String,
                          let colChildren = try? await notion.fetchBlockChildren(blockId: colId) else { continue }
                    for child in colChildren {
                        guard child["type"] as? String == "callout",
                              let callout = child["callout"] as? [String: Any],
                              NotionService.plainText(from: callout["rich_text"]) == "Today's Focus",
                              let calloutId = child["id"] as? String else { continue }
                        if let focusChildren = try? await notion.fetchBlockChildren(blockId: calloutId) {
                            for focusChild in focusChildren {
                                guard focusChild["type"] as? String == "to_do",
                                      let toDo = focusChild["to_do"] as? [String: Any] else { continue }
                                mit = NotionService.plainText(from: toDo["rich_text"])
                                mitCompleted = toDo["checked"] as? Bool ?? false
                                break
                            }
                        }
                        break
                    }
                }
                continue
            }

            if type == "callout" {
                if inTasks { inTasks = false }

                let callout = block["callout"] as? [String: Any]
                let title = NotionService.plainText(from: callout?["rich_text"])
                let color = callout?["color"] as? String ?? ""
                let blockId = block["id"] as? String ?? ""

                if title == "Tasks" {
                    inTasks = true
                    if !blockId.isEmpty, let children = try? await notion.fetchBlockChildren(blockId: blockId) {
                        for child in children {
                            guard child["type"] as? String == "to_do",
                                  let toDo = child["to_do"] as? [String: Any],
                                  toDo["checked"] as? Bool == true else { continue }
                            let text = NotionService.plainText(from: toDo["rich_text"])
                            if !text.isEmpty { completedTasks.append(text) }
                        }
                    }
                    continue
                }

                if color == "purple_background", !blockId.isEmpty {
                    reflectionQuestion = title
                    // Try children first (answer typed inside the callout)
                    if let children = try? await notion.fetchBlockChildren(blockId: blockId) {
                        reflectionAnswer = children.compactMap { child -> String? in
                            let t = child["type"] as? String ?? ""
                            if t == "paragraph" {
                                return NotionService.plainText(from: (child["paragraph"] as? [String: Any])?["rich_text"])
                            }
                            if t == "to_do" {
                                return NotionService.plainText(from: (child["to_do"] as? [String: Any])?["rich_text"])
                            }
                            return nil
                        }.filter { !$0.isEmpty }.joined(separator: " ")
                    }
                    // If no children, look for page-level paragraphs below the callout
                    if reflectionAnswer.isEmpty { afterReflection = true }
                }

                continue
            }

            if inTasks, type == "to_do",
               let toDo = block["to_do"] as? [String: Any],
               toDo["checked"] as? Bool == true {
                let text = NotionService.plainText(from: toDo["rich_text"])
                if !text.isEmpty { completedTasks.append(text) }
            }
        }

        return WeeklyDayData(
            displayDate: displayDate,
            mit: mit,
            mitCompleted: mitCompleted,
            reflectionQuestion: reflectionQuestion,
            reflectionAnswer: reflectionAnswer,
            completedTasks: completedTasks,
            meetings: meetings
        )
    }

    private func createWeeklyPage(title: String, summary: ClaudeService.WeeklyReviewContent) async throws -> String {
        let pageId = try await notion.createPage(
            parentPageId: weeklySummariesPageId,
            title: title,
            icon: "📋"
        )

        var blocks: [[String: Any]] = [
            NotionService.heading(2, "Overview"),
            NotionService.paragraph(summary.overview)
        ]

        if !summary.wins.isEmpty {
            blocks.append(NotionService.heading(2, "Wins"))
            blocks += summary.wins.map { NotionService.bulletedListItem($0) }
        }

        if !summary.blockers.isEmpty {
            blocks.append(NotionService.heading(2, "What got in the way"))
            blocks += summary.blockers.map { NotionService.bulletedListItem($0) }
        }

        blocks.append(NotionService.heading(2, "Focus for next week"))
        blocks.append(NotionService.paragraph(summary.nextWeekFocus))

        try? await notion.appendBlocks(to: pageId, blocks: blocks)
        return pageId
    }

    // MARK: - Helpers

    private var isMonday: Bool {
        Calendar(identifier: .gregorian).component(.weekday, from: Date()) == 2
    }

    private func currentWeekKey() -> String {
        let cal = Calendar(identifier: .iso8601)
        let week = cal.component(.weekOfYear, from: Date())
        let year = cal.component(.yearForWeekOfYear, from: Date())
        return "\(year)-W\(String(format: "%02d", week))"
    }

    private func weekPageTitle(weeksAgo: Int) -> String {
        let monday = mondayOfWeeksAgo(weeksAgo)
        let friday = Calendar(identifier: .gregorian).date(byAdding: .day, value: 4, to: monday)!

        let weekNum = Calendar(identifier: .iso8601).component(.weekOfYear, from: monday)

        let shortFormatter = DateFormatter()
        shortFormatter.dateFormat = "MMM d"

        let longFormatter = DateFormatter()
        longFormatter.dateFormat = "MMM d, yyyy"

        return "Week \(weekNum) · \(shortFormatter.string(from: monday))–\(longFormatter.string(from: friday))"
    }

    private func mondayOfWeeksAgo(_ weeksAgo: Int) -> Date {
        let cal = Calendar(identifier: .gregorian)
        let today = cal.startOfDay(for: Date())
        let weekday = cal.component(.weekday, from: today) // 1=Sun, 2=Mon, ..., 7=Sat
        let daysFromMonday = (weekday + 5) % 7
        let thisMonday = cal.date(byAdding: .day, value: -daysFromMonday, to: today)!
        return cal.date(byAdding: .day, value: -(7 * weeksAgo), to: thisMonday)!
    }
}
