import Foundation
import Combine

class TodayPageManager: ObservableObject {
    static let shared = TodayPageManager()
    private init() {}

    private let notion = NotionService.shared

    private var parentPageId: String { UserDefaults.shared.string(forKey: "notionParentPageId") ?? "" }
    private var archivePageId: String { UserDefaults.shared.string(forKey: "hivemind.archivePageId") ?? "" }
    private var projectsDbId: String { UserDefaults.shared.string(forKey: "hivemind.projectsDbId") ?? "" }

    private var todayPageId: String {
        get { UserDefaults.shared.string(forKey: "hivemind.todayPageId") ?? "" }
        set { UserDefaults.shared.set(newValue, forKey: "hivemind.todayPageId") }
    }

    // MARK: - Public

    func ensureToday() async {
        guard !parentPageId.isEmpty else { return }
        let today = dateString(from: Date())
        let lastDate = UserDefaults.shared.string(forKey: "hivemind.lastDailyDate") ?? ""
        guard lastDate != today else { return }

        let yesterdayPageId = todayPageId

        if !yesterdayPageId.isEmpty && !archivePageId.isEmpty {
            try? await notion.movePage(pageId: yesterdayPageId, newParentPageId: archivePageId)
            if !lastDate.isEmpty {
                try? await notion.updatePage(pageId: yesterdayPageId, properties: [
                    "title": ["title": [["type": "text", "text": ["content": lastDate]]]]
                ])
            }
        }

        guard let newPageId = try? await notion.createPage(
            parentPageId: parentPageId,
            title: "Hivemind - \(today)",
            icon: "🧠"
        ) else { return }

        UserDefaults.shared.set(today, forKey: "hivemind.lastDailyDate")
        UserDefaults.shared.set(yesterdayPageId, forKey: "hivemind.yesterdayPageId")
        UserDefaults.shared.set(newPageId, forKey: "hivemind.pageId.\(today)")
        todayPageId = newPageId
        clearCachedBlockIds()

        await writeTemplateHeader(to: newPageId, yesterdayPageId: yesterdayPageId)
        if !yesterdayPageId.isEmpty {
            await rollover(from: yesterdayPageId, to: newPageId)
        }
        await writeTemplateFooter(to: newPageId)
        try? await populateSchedule(pageId: newPageId)
    }

    func refreshActiveProjects() async {
        guard !todayPageId.isEmpty else { return }
        await deleteActiveProjectsBlock()
        await createActiveProjectsBlock(pageId: todayPageId)
    }

    func refreshSchedule() async {
        guard !todayPageId.isEmpty else { return }
        try? await populateSchedule(pageId: todayPageId)
    }

    func forceCreateToday() async {
        UserDefaults.shared.removeObject(forKey: "hivemind.lastDailyDate")
        await ensureToday()
    }

    // MARK: - Template

    private func writeTemplateHeader(to pageId: String, yesterdayPageId: String) async {
        await createActiveProjectsBlock(pageId: pageId)

        try? await notion.appendBlocks(to: pageId, blocks: [
            NotionService.heading(1, displayDateString(from: Date()))
        ])

        // Yesterday's Wins — yellow (warmer), conditional
        let wins = await fetchYesterdayWins(from: yesterdayPageId)
        if !wins.isEmpty {
            let bullets = wins.map { NotionService.bulletedListItem($0) }
            let winsBlock: [String: Any] = [
                "object": "block", "type": "callout",
                "callout": [
                    "rich_text": NotionService.richText("Yesterday's Wins"),
                    "icon": ["type": "emoji", "emoji": "🏆"],
                    "color": "yellow_background"
                ] as [String: Any]
            ]
            if let winsId = (try? await notion.appendBlocksReturningIds(to: pageId, blocks: [winsBlock]))?.first {
                try? await notion.appendBlocks(to: winsId, blocks: bullets)
            }
        }

        // Focus (left) + Schedule (right) as two columns
        let focusCallout: [String: Any] = [
            "object": "block", "type": "callout",
            "callout": [
                "rich_text": NotionService.richText("Today's Focus"),
                "icon": ["type": "emoji", "emoji": "🎯"],
                "color": "blue_background"
            ] as [String: Any]
        ]
        let scheduleCallout: [String: Any] = [
            "object": "block", "type": "callout",
            "callout": [
                "rich_text": NotionService.richText("Schedule"),
                "icon": ["type": "emoji", "emoji": "🗓"],
                "color": "brown_background"
            ] as [String: Any]
        ]
        let columns = NotionService.columnList(left: [focusCallout], right: [scheduleCallout])

        if let columnListId = (try? await notion.appendBlocksReturningIds(to: pageId, blocks: [columns]))?.first,
           let cols = try? await notion.fetchBlockChildren(blockId: columnListId),
           cols.count >= 2 {
            // Add MIT placeholder to_do inside the Focus callout
            if let leftColId = cols[0]["id"] as? String,
               let leftChildren = try? await notion.fetchBlockChildren(blockId: leftColId),
               let focusId = leftChildren.first?["id"] as? String {
                try? await notion.appendBlocks(to: focusId, blocks: [NotionService.toDo("MIT: ")])
            }
            // Cache the Schedule callout ID for later refreshes
            if let rightColId = cols[1]["id"] as? String,
               let rightChildren = try? await notion.fetchBlockChildren(blockId: rightColId),
               let scheduleId = rightChildren.first?["id"] as? String {
                UserDefaults.shared.set(scheduleId, forKey: "hivemind.scheduleCalloutBlockId")
            }
        }

        let tasksBlock: [String: Any] = [
            "object": "block", "type": "callout",
            "callout": [
                "rich_text": NotionService.richText("Tasks"),
                "icon": ["type": "emoji", "emoji": "✅"],
                "color": "gray_background"
            ] as [String: Any]
        ]
        try? await notion.appendBlocks(to: pageId, blocks: [tasksBlock])
    }

    private func writeTemplateFooter(to pageId: String) async {
        let question = todayReflectionQuestion()
        try? await notion.appendBlocks(to: pageId, blocks: [
            NotionService.callout("📝", "Notes", color: "yellow_background"),
            NotionService.callout("💬", todayQuote(), color: "gray_background"),
            NotionService.callout("💭", question, color: "purple_background")
        ])
    }

    // MARK: - Yesterday's Wins

    private func fetchYesterdayWins(from pageId: String) async -> [String] {
        guard !pageId.isEmpty,
              let blocks = try? await notion.fetchBlockChildren(blockId: pageId) else { return [] }

        var wins: [String] = []

        // MIT: checked to_do inside the Today's Focus callout
        for block in blocks {
            guard block["type"] as? String == "callout",
                  calloutTitle(from: block) == "Today's Focus",
                  let calloutId = block["id"] as? String else { continue }

            if let focusChildren = try? await notion.fetchBlockChildren(blockId: calloutId) {
                for child in focusChildren {
                    guard child["type"] as? String == "to_do",
                          let toDo = child["to_do"] as? [String: Any],
                          toDo["checked"] as? Bool == true else { continue }
                    let text = plainText(from: toDo["rich_text"])
                    if !text.isEmpty { wins.append(text) }
                }
            }
            break
        }

        // Checked to_dos inside the Tasks callout (added directly in Notion)
        // and at page level after it (added via Noted)
        for block in blocks {
            guard block["type"] as? String == "callout",
                  calloutTitle(from: block) == "Tasks",
                  let calloutId = block["id"] as? String else { continue }

            if let children = try? await notion.fetchBlockChildren(blockId: calloutId) {
                for child in children {
                    guard child["type"] as? String == "to_do",
                          let toDo = child["to_do"] as? [String: Any],
                          toDo["checked"] as? Bool == true else { continue }
                    let text = plainText(from: toDo["rich_text"])
                    if !text.isEmpty { wins.append(text) }
                }
            }
            break
        }

        // Also check page-level to_dos after the Tasks callout (Noted synced tasks)
        var inTasks = false
        for block in blocks {
            let type = block["type"] as? String ?? ""
            if type == "callout" {
                let title = calloutTitle(from: block)
                if title == "Tasks" { inTasks = true; continue }
                if inTasks { break }
            }
            guard inTasks, type == "to_do",
                  let toDo = block["to_do"] as? [String: Any],
                  toDo["checked"] as? Bool == true else { continue }
            let text = plainText(from: toDo["rich_text"])
            if !text.isEmpty { wins.append(text) }
        }

        return wins
    }

    // MARK: - Reflection Questions

    private func todayReflectionQuestion() -> String {
        let dayOfYear = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 1
        return reflectionQuestions[(dayOfYear - 1) % reflectionQuestions.count]
    }

    private func todayQuote() -> String {
        let dayOfYear = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 1
        return dailyQuotes[(dayOfYear) % dailyQuotes.count]
    }

    private let dailyQuotes: [String] = [
        // Leadership & Decision-making
        "Be stubborn on vision but flexible on details. — Jeff Bezos",
        "Management is doing things right; leadership is doing the right things. — Peter Drucker",
        "Culture eats strategy for breakfast. — Peter Drucker",
        "The most important decisions are not what to do, but what to stop doing. — Peter Drucker",
        "Strong opinions, weakly held. — Paul Saffo",
        "If you can't disagree with me, you can't help me. — Andy Grove",
        "High-output management means training your people to make the decisions you would make. — Andy Grove",
        "As an engineering leader, your output is the output of your team. — Andy Grove",
        "Speed matters in business. A ferocious sense of urgency is something you can manufacture. — Jeff Bezos",
        "The best managers figure out how to get great outcomes by setting context, not by controlling people. — Reed Hastings",
        "The function of leadership is to produce more leaders, not more followers. — Ralph Nader",
        "The art of leadership is saying no, not yes. It is very easy to say yes. — Tony Blair",
        "A players hire A players; B players hire C players. — Steve Jobs",
        "Be a yardstick of quality. Some people aren't used to an environment where excellence is expected. — Steve Jobs",
        "You manage things; you lead people. — Grace Hopper",
        "Leadership is not about being in charge. It is about taking care of those in your charge. — Simon Sinek",
        "Vision without execution is hallucination. — Thomas Edison",
        "If everyone is thinking alike, then somebody isn't thinking. — George S. Patton",
        "There are no solutions. There are only trade-offs. — Thomas Sowell",
        "Strategy without tactics is the slowest route to victory. Tactics without strategy is the noise before defeat. — Sun Tzu",
        "Plans are worthless, but planning is everything. — Dwight D. Eisenhower",
        "In preparing for battle I have always found that plans are useless, but planning is indispensable. — Dwight D. Eisenhower",
        // Systems thinking
        "A complex system that works evolved from a simple system that worked. — John Gall",
        "You do not rise to the level of your goals. You fall to the level of your systems. — James Clear",
        "Every system is perfectly designed to get the results it gets. — W. Edwards Deming",
        "All models are wrong, but some are useful. — George Box",
        "Organizations that design systems are constrained to produce designs which are copies of their communication structures. — Melvin Conway",
        "The problem is never how to get new, innovative thoughts into your mind, but how to get old ones out. — Dee Hock",
        "In theory, theory and practice are the same. In practice, they are not. — Various",
        // Engineering craft
        "Simplicity is a prerequisite for reliability. — Edsger W. Dijkstra",
        "Measuring programming progress by lines of code is like measuring aircraft building progress by weight. — Bill Gates",
        "The most dangerous phrase is 'we've always done it this way.' — Grace Hopper",
        "Any fool can write code that a computer can understand. Good programmers write code that humans can understand. — Martin Fowler",
        "Make it work, make it right, make it fast. — Kent Beck",
        "Programs must be written for people to read, and only incidentally for machines to execute. — Abelson & Sussman",
        "Debugging is twice as hard as writing the code in the first place. Therefore, if you write the code as cleverly as possible, you are, by definition, not smart enough to debug it. — Brian Kernighan",
        "The function of good software is to make the complex appear to be simple. — Grady Booch",
        "The best code is no code at all. — Jeff Atwood",
        "First, solve the problem. Then, write the code. — John Johnson",
        "The most important property of a program is whether it accomplishes the intention of its user. — C.A.R. Hoare",
        "Technical debt is like a loan: manageable in small amounts, catastrophic when it compounds. — Ward Cunningham",
        // Team & Scale
        "Talent wins games, but teamwork and intelligence win championships. — Michael Jordan",
        "If you want to go fast, go alone. If you want to go far, go together. — African Proverb",
        "Trust is the lubrication that makes it possible for organizations to work. — Warren Bennis",
        "Psychological safety is the belief that one won't be punished or humiliated for speaking up. — Amy Edmondson",
        "An organization's ability to learn, and translate that learning into action rapidly, is the ultimate competitive advantage. — Jack Welch",
        "The best teams aren't the ones with the most talented individuals. They're the ones that communicate best. — Tom DeMarco",
        "Your most unhappy customers are your greatest source of learning. — Bill Gates",
        // Long-term thinking
        "We overestimate what we can do in a year and underestimate what we can do in a decade. — Bill Gates",
        "The best time to plant a tree was twenty years ago. The second best time is now. — Chinese Proverb",
        "The reasonable man adapts himself to the world; the unreasonable one persists in trying to adapt the world to himself. Therefore all progress depends on the unreasonable man. — George Bernard Shaw",
        "An expert is a man who has made all the mistakes which can be made in a very narrow field. — Niels Bohr",
        "I have not failed. I've just found 10,000 ways that won't work. — Thomas Edison",
        "It is not that I'm so smart. It's just that I stay with problems longer. — Albert Einstein",
        "Everything should be made as simple as possible, but no simpler. — Albert Einstein",
        "The measure of intelligence is the ability to change. — Albert Einstein",
        // Stoic philosophy
        "The impediment to action advances action. What stands in the way becomes the way. — Marcus Aurelius",
        "You have power over your mind, not outside events. Realize this, and you will find strength. — Marcus Aurelius",
        "Waste no more time arguing about what a good man should be. Be one. — Marcus Aurelius",
        "The object of life is not to be on the side of the majority, but to escape finding oneself in the ranks of the insane. — Marcus Aurelius",
        "Luck is what happens when preparation meets opportunity. — Seneca",
        "It is not the man who has too little who is poor, but the man who craves more. — Seneca",
        "We suffer more in imagination than in reality. — Seneca",
        "No man is free who is not master of himself. — Epictetus",
        "Men are disturbed not by the things which happen, but by the opinions about the things. — Epictetus",
        "Seek not that the things which happen should happen as you wish; but wish the things which happen to be as they are. — Epictetus",
        // Decision under uncertainty
        "The goal is not to be certain. The goal is to be less wrong over time. — Shane Parrish",
        "If I had an hour to solve a problem, I'd spend 55 minutes thinking about the problem and 5 minutes thinking about solutions. — Albert Einstein",
        // Broader wisdom
        "We are what we repeatedly do. Excellence, then, is not an act but a habit. — Aristotle",
        "The unexamined life is not worth living. — Socrates",
        "He who has a why to live can bear almost any how. — Friedrich Nietzsche",
        "The more constraints one imposes, the more one frees oneself. — Igor Stravinsky",
        "The price of anything is the amount of life you exchange for it. — Henry David Thoreau",
        "Do I not destroy my enemies when I make them my friends? — Abraham Lincoln",
        "Without continual growth and progress, such words as improvement, achievement, and success have no meaning. — Benjamin Franklin",
        "The most effective way to do it is to do it. — Amelia Earhart",
        "Don't let the urgent crowd out the important. — Various"
    ]

    private let reflectionQuestions: [String] = [
        // End-of-day / retrospective
        "What's the one thing I actually moved forward today?",
        "What surprised me today?",
        "What decision did I avoid today?",
        "What would I tell my morning self?",
        "What did I ship that I'm proud of?",
        "What got in my way today?",
        "What drained my energy most today?",
        "What gave me energy today?",
        "What did I leave half-done, and why?",
        "Who helped me today without being asked?",
        "What problem am I still carrying that I should let go of?",
        "What's been on my list for 3+ days that probably shouldn't be?",
        "What did I learn today?",
        "What would I do differently if I had today again?",
        "What's the most important thing I didn't do today?",
        "Did I do my MIT today? What got in the way if not?",
        "What conversation do I need to have that I'm putting off?",
        "What distracted me most today?",
        "What am I overthinking right now?",
        "What was the hardest decision I made today?",
        "What am I most uncertain about right now?",
        "What assumption am I making that might be wrong?",
        "What's quietly going wrong that I haven't addressed?",
        "What would 'done well' have looked like today?",
        "Did I protect any time for deep work today?",
        "What can I delegate or drop that I'm still holding?",
        "What am I doing out of habit that I should question?",
        "What's the smallest thing that would have made today better?",
        "What did I say yes to that I should have said no to?",
        "What's the gap between what I planned and what I did?",
        "What conversation from today is still in my head?",
        "What's one thing I can do tomorrow that I didn't do today?",
        "What's eating my attention that I haven't consciously chosen?",
        "What's a small win I almost didn't notice today?",
        "What does 'enough' look like for today?",
        // Morning / intention-focused
        "What would make today a success?",
        "What am I avoiding that needs to happen today?",
        "What's the most important conversation I need to have this week?",
        "What am I most anxious about right now?",
        "What would future-me thank me for doing today?",
        "What's the one thing that, if done, makes everything else easier?",
        "What do I need to stop doing to make room for what matters?",
        "Where do I need to say no this week?",
        "What's been unclear that needs a decision?",
        "What's the one thing I keep postponing?",
        "What do I need that I haven't asked for?",
        "What would I regret not doing this month?",
        "What's the next step on the thing I care most about?",
        // Neutral / anytime
        "Am I working on the right things?",
        "What would I cut if I had half the time?",
        "What's a problem I've been solving the wrong way?",
        "What do I know now that I wish I'd known last week?",
        "What's the most valuable thing I could do with one free hour?",
        "What am I pretending is not a problem?",
        "What would a great week look like from here?",
        "What's the real blocker — not the surface one?",
        "What's working that I should do more of?",
        "What's the thing I'm most afraid to write down?",
        "What's taking more energy than it should?",
        "What's a belief about my work that might be limiting me?",
        "What would I do today if I knew I couldn't fail?",
        "What's been left unsaid that needs to be said?",
        "What's the quality of my focus been like lately?",
        "What do I need to accept that I've been resisting?",
        "What do I wish someone had told me this week?",
        "What's the question I should be asking that I'm not?",
        "What would I do if I had twice the energy tomorrow?",
        "What's worth remembering from this week?"
    ]

    // MARK: - Active Projects

    private func createActiveProjectsBlock(pageId: String) async {
        guard !projectsDbId.isEmpty else { return }
        guard let allProjects = try? await notion.queryDatabase(databaseId: projectsDbId) else { return }

        let active = allProjects.filter(isActive)
        guard !active.isEmpty else { return }

        var richTextItems: [[String: Any]] = []
        for (i, project) in active.enumerated() {
            guard let projectId = project["id"] as? String,
                  let name = projectName(from: project), !name.isEmpty else { continue }

            var color = projectColor(from: project)
            if color.isEmpty {
                color = autoColor(for: name)
                try? await notion.updatePage(pageId: projectId, properties: [
                    "Color": ["select": ["name": color]]
                ])
            }

            if i > 0 { richTextItems.append(["type": "text", "text": ["content": "  "]]) }
            richTextItems.append([
                "type": "mention",
                "mention": ["type": "page", "page": ["id": projectId]],
                "annotations": ["color": "\(color)_background"]
            ])
        }
        guard !richTextItems.isEmpty else { return }

        let block = NotionService.callout("📂", richTextItems: richTextItems, color: "green_background")
        if let blockId = (try? await notion.appendBlocksReturningIds(to: pageId, blocks: [block]))?.first {
            UserDefaults.shared.set(blockId, forKey: "hivemind.activeProjectsBlockId")
        }
    }

    private func deleteActiveProjectsBlock() async {
        let storedId = UserDefaults.shared.string(forKey: "hivemind.activeProjectsBlockId") ?? ""
        if !storedId.isEmpty {
            if (try? await notion.deleteBlock(id: storedId)) != nil {
                UserDefaults.shared.removeObject(forKey: "hivemind.activeProjectsBlockId")
                return
            }
        }
        guard let blocks = try? await notion.fetchBlockChildren(blockId: todayPageId) else { return }
        for block in blocks {
            guard block["type"] as? String == "callout",
                  let callout = block["callout"] as? [String: Any],
                  let icon = callout["icon"] as? [String: Any],
                  icon["emoji"] as? String == "📂",
                  let id = block["id"] as? String else { continue }
            try? await notion.deleteBlock(id: id)
            UserDefaults.shared.removeObject(forKey: "hivemind.activeProjectsBlockId")
            break
        }
    }

    // MARK: - Schedule

    private func populateSchedule(pageId: String) async throws {
        let urlString = UserDefaults.standard.string(forKey: "hivemind.calendarUrl") ?? ""
        guard !urlString.isEmpty else { return }

        let events = try await ICSParser.fetchAndParse(urlString: urlString)
        let today = Calendar.current.startOfDay(for: Date())
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        let todayEvents = events
            .filter { $0.startDate >= today && $0.startDate < tomorrow }
            .sorted { $0.startDate < $1.startDate }

        let scheduleCalloutId = try await resolveScheduleCalloutId(pageId: pageId)
        guard !scheduleCalloutId.isEmpty else { return }

        let existing = (try? await notion.fetchBlockChildren(blockId: scheduleCalloutId)) ?? []
        for block in existing {
            if let id = block["id"] as? String { try? await notion.deleteBlock(id: id) }
        }

        guard !todayEvents.isEmpty else {
            let placeholder: [String: Any] = ["object": "block", "type": "paragraph", "paragraph": [
                "rich_text": [["type": "text", "text": ["content": "No events today"],
                               "annotations": ["color": "gray"]]]
            ] as [String: Any]]
            try? await notion.appendBlocks(to: scheduleCalloutId, blocks: [placeholder])
            return
        }

        let now = Date()
        let blocks = todayEvents.map { event -> [String: Any] in
            let label = "\(event.timeString)  \(event.summary)"
            let isPast = !event.isAllDay && event.endDate < now
            if isPast {
                return ["object": "block", "type": "bulleted_list_item", "bulleted_list_item": [
                    "rich_text": [["type": "text", "text": ["content": label],
                                   "annotations": ["strikethrough": true, "color": "gray"]]]
                ] as [String: Any]]
            }
            return NotionService.bulletedListItem(label)
        }
        try? await notion.appendBlocks(to: scheduleCalloutId, blocks: blocks)
    }

    private func resolveScheduleCalloutId(pageId: String) async throws -> String {
        let stored = UserDefaults.shared.string(forKey: "hivemind.scheduleCalloutBlockId") ?? ""
        if !stored.isEmpty { return stored }

        let blocks = try await notion.fetchBlockChildren(blockId: pageId)

        // Old page format: Schedule callout at top level
        if let id = blocks.first(where: {
            $0["type"] as? String == "callout" && calloutTitle(from: $0) == "Schedule"
        })?["id"] as? String {
            UserDefaults.shared.set(id, forKey: "hivemind.scheduleCalloutBlockId")
            return id
        }

        // New page format: Schedule callout inside a column_list
        for block in blocks where block["type"] as? String == "column_list" {
            guard let colListId = block["id"] as? String else { continue }
            let cols = (try? await notion.fetchBlockChildren(blockId: colListId)) ?? []
            for col in cols {
                guard let colId = col["id"] as? String else { continue }
                let children = (try? await notion.fetchBlockChildren(blockId: colId)) ?? []
                if let id = children.first(where: {
                    $0["type"] as? String == "callout" && calloutTitle(from: $0) == "Schedule"
                })?["id"] as? String {
                    UserDefaults.shared.set(id, forKey: "hivemind.scheduleCalloutBlockId")
                    return id
                }
            }
        }

        return ""
    }

    // MARK: - Rollover

    private func rollover(from yesterdayPageId: String, to newPageId: String) async {
        guard let blocks = try? await notion.fetchBlockChildren(blockId: yesterdayPageId) else { return }

        var inTasksSection = false
        var syncedRefs: [[String: Any]] = []
        var plainToDos: [[String: Any]] = []

        for block in blocks {
            let type = block["type"] as? String ?? ""
            let blockId = block["id"] as? String ?? ""

            if type == "callout" {
                let title = calloutTitle(from: block)
                if title == "Tasks" { inTasksSection = true; continue }
                if inTasksSection { break }
            }

            guard inTasksSection, !blockId.isEmpty else { continue }

            if type == "synced_block" {
                let syncedFrom = (block["synced_block"] as? [String: Any])?["synced_from"] as? [String: Any]
                let originalId = syncedFrom?["block_id"] as? String ?? blockId
                let unchecked = await isSyncedBlockUnchecked(blockId: blockId)
                if unchecked {
                    syncedRefs.append(["object": "block", "type": "synced_block",
                        "synced_block": ["synced_from": ["block_id": originalId] as [String: Any]] as [String: Any]])
                }
            } else if type == "to_do" {
                let toDo = block["to_do"] as? [String: Any]
                let checked = toDo?["checked"] as? Bool ?? false
                if !checked { plainToDos.append(block) }
            }
        }

        var toAppend = syncedRefs
        toAppend += plainToDos.map { block -> [String: Any] in
            let toDo = block["to_do"] as? [String: Any]
            let richText = toDo?["rich_text"] as? [[String: Any]] ?? []
            return NotionService.toDo(richText.compactMap { $0["plain_text"] as? String }.joined())
        }

        guard !toAppend.isEmpty else { return }
        try? await notion.appendBlocks(to: newPageId, blocks: toAppend)
    }

    private func isSyncedBlockUnchecked(blockId: String) async -> Bool {
        guard let children = try? await notion.fetchBlockChildren(blockId: blockId) else { return false }
        for child in children {
            guard child["type"] as? String == "to_do",
                  let toDo = child["to_do"] as? [String: Any] else { continue }
            return !(toDo["checked"] as? Bool ?? false)
        }
        return false
    }

    // MARK: - Helpers

    private func clearCachedBlockIds() {
        UserDefaults.shared.removeObject(forKey: "hivemind.activeProjectsBlockId")
        UserDefaults.shared.removeObject(forKey: "hivemind.scheduleCalloutBlockId")
    }

    private func plainText(from richText: Any?) -> String {
        guard let items = richText as? [[String: Any]] else { return "" }
        return items.compactMap { $0["plain_text"] as? String }.joined()
    }

    private func isActive(_ project: [String: Any]) -> Bool {
        let props = project["properties"] as? [String: Any]
        let statusProp = props?["Status"] as? [String: Any]
        let selectName = (statusProp?["select"] as? [String: Any])?["name"] as? String
        let statusName = (statusProp?["status"] as? [String: Any])?["name"] as? String
        return selectName == "Active" || statusName == "Active"
    }

    private func projectName(from project: [String: Any]) -> String? {
        let props = project["properties"] as? [String: Any]
        return ((props?["Name"] as? [String: Any])?["title"] as? [[String: Any]])?.first?["plain_text"] as? String
    }

    private func projectColor(from project: [String: Any]) -> String {
        let props = project["properties"] as? [String: Any]
        return ((props?["Color"] as? [String: Any])?["select"] as? [String: Any])?["name"] as? String ?? ""
    }

    private func calloutTitle(from block: [String: Any]) -> String {
        guard let callout = block["callout"] as? [String: Any],
              let richText = callout["rich_text"] as? [[String: Any]] else { return "" }
        return richText.compactMap { $0["plain_text"] as? String }.joined()
    }

    private func autoColor(for name: String) -> String {
        let palette = ["red", "orange", "yellow", "green", "blue", "purple", "pink", "gray"]
        let hash = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[hash % palette.count]
    }

    private func dateString(from date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private func displayDateString(from date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d, yyyy"
        return f.string(from: date)
    }
}
