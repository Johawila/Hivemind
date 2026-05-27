import Foundation

struct ICSEvent {
    let uid: String
    let summary: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool

    var timeString: String {
        if isAllDay { return "All day" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = TimeZone.current
        return "\(f.string(from: startDate))–\(f.string(from: endDate))"
    }
}

class ICSParser {
    static func fetchAndParse(urlString: String) async throws -> [ICSEvent] {
        let normalized = urlString.replacingOccurrences(of: "webcal://", with: "https://")
        guard let url = URL(string: normalized) else { return [] }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return parse(text)
    }

    static func parse(_ ics: String) -> [ICSEvent] {
        var events: [ICSEvent] = []
        let lines = unfold(ics)
        var i = 0

        while i < lines.count {
            if lines[i] == "BEGIN:VEVENT" {
                var uid = UUID().uuidString
                var summary = ""
                var start: Date? = nil
                var end: Date? = nil
                var isAllDay = false
                var isCancelled = false

                i += 1
                while i < lines.count && lines[i] != "END:VEVENT" {
                    let line = lines[i]
                    if line.hasPrefix("UID:") {
                        uid = String(line.dropFirst(4))
                    } else if line.hasPrefix("SUMMARY:") {
                        summary = String(line.dropFirst(8))
                        let lower = summary.lowercased()
                        if lower.hasPrefix("canceled:") || lower.hasPrefix("cancelled:") ||
                           lower.hasPrefix("avbruten:") || lower.hasPrefix("inställt:") {
                            isCancelled = true
                        }
                    } else if line.hasPrefix("DTSTART") {
                        (start, isAllDay) = parseDate(line)
                    } else if line.hasPrefix("DTEND") {
                        (end, _) = parseDate(line)
                    } else if line == "STATUS:CANCELLED" || line == "STATUS:CANCELED" {
                        isCancelled = true
                    }
                    i += 1
                }

                if let s = start, let e = end, !isCancelled {
                    events.append(ICSEvent(uid: uid, summary: summary, startDate: s, endDate: e, isAllDay: isAllDay))
                }
            }
            i += 1
        }

        // Deduplicate by (uid, startDate) — feeds sometimes emit the same event twice
        var seen = Set<String>()
        return events.filter { seen.insert("\($0.uid)|\($0.startDate.timeIntervalSince1970)").inserted }
    }

    // MARK: - Private

    // ICS line folding: continuation lines start with a space or tab
    private static func unfold(_ ics: String) -> [String] {
        var result: [String] = []
        for line in ics.components(separatedBy: "\n") {
            let stripped = line.hasSuffix("\r") ? String(line.dropLast()) : line
            if (stripped.hasPrefix(" ") || stripped.hasPrefix("\t")) && !result.isEmpty {
                result[result.count - 1] += String(stripped.dropFirst())
            } else {
                result.append(stripped)
            }
        }
        return result
    }

    private static func windowsToIANA(_ name: String) -> TimeZone? {
        let map: [String: String] = [
            "W. Europe Standard Time": "Europe/Stockholm",
            "FLE Standard Time": "Europe/Helsinki",
            "GTB Standard Time": "Europe/Helsinki",
            "Central Europe Standard Time": "Europe/Warsaw",
            "Central European Standard Time": "Europe/Warsaw",
            "Romance Standard Time": "Europe/Paris",
            "GMT Standard Time": "Europe/London",
            "UTC": "UTC",
            "Eastern Standard Time": "America/New_York",
            "Pacific Standard Time": "America/Los_Angeles"
        ]
        return map[name].flatMap { TimeZone(identifier: $0) }
    }

    private static func parseDate(_ line: String) -> (Date?, Bool) {
        // Examples:
        // DTSTART:20260331T090000Z
        // DTSTART;TZID=Europe/Stockholm:20260331T090000
        // DTSTART;VALUE=DATE:20260331
        guard let colon = line.firstIndex(of: ":") else { return (nil, false) }
        let params = String(line[line.startIndex..<colon])
        let value = String(line[line.index(after: colon)...])

        let isAllDay = params.contains("VALUE=DATE") || value.count == 8
        if isAllDay {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd"
            f.timeZone = TimeZone.current
            return (f.date(from: value), true)
        }

        var timeZone: TimeZone = .current
        if let tzRange = params.range(of: "TZID=") {
            let tzStr = String(params[tzRange.upperBound...]).components(separatedBy: ";").first ?? ""
            timeZone = TimeZone(identifier: tzStr) ?? windowsToIANA(tzStr) ?? .current
        }

        let isUTC = value.hasSuffix("Z")
        let dateStr = isUTC ? String(value.dropLast()) : value
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        f.timeZone = isUTC ? .init(identifier: "UTC")! : timeZone

        return (f.date(from: dateStr), false)
    }
}
