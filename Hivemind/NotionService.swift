import Foundation

enum NotionError: Error, LocalizedError {
    case notConfigured
    case apiError(Int, String)
    case missingField(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Notion API key is not configured."
        case .apiError(let status, let message):
            return "Notion API error (\(status)): \(message)"
        case .missingField(let field):
            return "Missing expected field in Notion response: \(field)"
        }
    }
}

class NotionService {
    static let shared = NotionService()
    private init() {}

    private let baseURL = "https://api.notion.com/v1"
    private let notionVersion = "2022-06-28"

    var apiKey: String {
        UserDefaults.shared.string(forKey: "notionApiKey") ?? ""
    }

    // MARK: - Pages

    func updateDatabaseProperties(databaseId: String, properties: [String: Any]) async throws {
        let url = URL(string: "\(baseURL)/databases/\(databaseId)")!
        var request = makeRequest(url: url, method: "PATCH")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["properties": properties])
        _ = try await perform(request)
    }

    func updateIcon(id: String, emoji: String, isDatabase: Bool = false) async throws {
        let endpoint = isDatabase ? "databases" : "pages"
        let url = URL(string: "\(baseURL)/\(endpoint)/\(id)")!
        var request = makeRequest(url: url, method: "PATCH")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["icon": ["type": "emoji", "emoji": emoji]])
        _ = try await perform(request)
    }

    func archivePage(id: String) async throws {
        let url = URL(string: "\(baseURL)/pages/\(id)")!
        var request = makeRequest(url: url, method: "PATCH")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["archived": true])
        _ = try await perform(request)
    }

    func movePage(pageId: String, newParentPageId: String) async throws {
        let url = URL(string: "\(baseURL)/pages/\(pageId)/move")!
        var request = makeRequest(url: url, method: "POST")
        request.setValue("2026-03-11", forHTTPHeaderField: "Notion-Version")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "parent": ["type": "page_id", "page_id": newParentPageId]
        ])
        _ = try await perform(request)
    }

func findChildDatabase(parentPageId: String, title: String) async throws -> String? {
        let url = URL(string: "\(baseURL)/blocks/\(parentPageId)/children?page_size=100")!
        let request = makeRequest(url: url, method: "GET")
        let data = try await perform(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let results = json?["results"] as? [[String: Any]] ?? []
        return results.first {
            $0["type"] as? String == "child_database" &&
            ($0["child_database"] as? [String: Any])?["title"] as? String == title
        }?["id"] as? String
    }

    func findChildPage(parentPageId: String, title: String) async throws -> String? {
        let url = URL(string: "\(baseURL)/blocks/\(parentPageId)/children?page_size=100")!
        let request = makeRequest(url: url, method: "GET")
        let data = try await perform(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let results = json?["results"] as? [[String: Any]] ?? []
        return results.first {
            $0["type"] as? String == "child_page" &&
            ($0["child_page"] as? [String: Any])?["title"] as? String == title
        }?["id"] as? String
    }

    func deleteBlock(id: String) async throws {
        let url = URL(string: "\(baseURL)/blocks/\(id)")!
        var request = makeRequest(url: url, method: "DELETE")
        request.httpBody = nil
        _ = try await perform(request)
    }

    func createPage(parentPageId: String, title: String, icon: String? = nil, children: [[String: Any]] = []) async throws -> String {
        let url = URL(string: "\(baseURL)/pages")!
        var request = makeRequest(url: url, method: "POST")

        var body: [String: Any] = [
            "parent": ["page_id": parentPageId],
            "properties": [
                "title": ["title": [["type": "text", "text": ["content": title]]]]
            ]
        ]
        if let icon { body["icon"] = ["type": "emoji", "emoji": icon] }
        if !children.isEmpty { body["children"] = children }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await perform(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = json?["id"] as? String else { throw NotionError.missingField("id") }
        return id
    }

    // MARK: - Databases

    func createDatabase(parentPageId: String, title: String, icon: String? = nil, properties: [String: Any]) async throws -> String {
        let url = URL(string: "\(baseURL)/databases")!
        var request = makeRequest(url: url, method: "POST")

        var body: [String: Any] = [
            "parent": ["page_id": parentPageId],
            "title": [["type": "text", "text": ["content": title]]],
            "properties": properties
        ]
        if let icon { body["icon"] = ["type": "emoji", "emoji": icon] }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await perform(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = json?["id"] as? String else { throw NotionError.missingField("id") }
        return id
    }

    func queryDatabase(databaseId: String, filter: [String: Any]? = nil, sorts: [[String: Any]]? = nil, pageSize: Int? = nil) async throws -> [[String: Any]] {
        let url = URL(string: "\(baseURL)/databases/\(databaseId)/query")!
        var request = makeRequest(url: url, method: "POST")

        var body: [String: Any] = [:]
        if let filter { body["filter"] = filter }
        if let sorts { body["sorts"] = sorts }
        if let pageSize { body["page_size"] = pageSize }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await perform(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["results"] as? [[String: Any]] ?? []
    }

    func createPageInDatabase(databaseId: String, properties: [String: Any], children: [[String: Any]] = []) async throws -> String {
        let url = URL(string: "\(baseURL)/pages")!
        var request = makeRequest(url: url, method: "POST")

        var body: [String: Any] = [
            "parent": ["database_id": databaseId],
            "properties": properties
        ]
        if !children.isEmpty { body["children"] = children }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await perform(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = json?["id"] as? String else { throw NotionError.missingField("id") }
        return id
    }

    // MARK: - Blocks

    func fetchBlockChildren(blockId: String) async throws -> [[String: Any]] {
        let url = URL(string: "\(baseURL)/blocks/\(blockId)/children?page_size=100")!
        let request = makeRequest(url: url, method: "GET")
        let data = try await perform(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["results"] as? [[String: Any]] ?? []
    }

    func appendBlock(to blockId: String, block: [String: Any], afterId: String? = nil) async throws {
        try await appendBlocks(to: blockId, blocks: [block], afterId: afterId)
    }

    func appendBlocks(to blockId: String, blocks: [[String: Any]], afterId: String? = nil) async throws {
        let url = URL(string: "\(baseURL)/blocks/\(blockId)/children")!
        var request = makeRequest(url: url, method: "PATCH")

        var body: [String: Any] = ["children": blocks]
        if let afterId { body["after"] = afterId }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await perform(request)
    }

    func appendBlocksReturningIds(to blockId: String, blocks: [[String: Any]], afterId: String? = nil) async throws -> [String] {
        let url = URL(string: "\(baseURL)/blocks/\(blockId)/children")!
        var request = makeRequest(url: url, method: "PATCH")

        var body: [String: Any] = ["children": blocks]
        if let afterId { body["after"] = afterId }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await perform(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["results"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
    }

    func updateBlock(blockId: String, properties: [String: Any]) async throws {
        let url = URL(string: "\(baseURL)/blocks/\(blockId)")!
        var request = makeRequest(url: url, method: "PATCH")
        request.httpBody = try JSONSerialization.data(withJSONObject: properties)
        _ = try await perform(request)
    }

    func fetchPage(pageId: String) async throws -> [String: Any] {
        let url = URL(string: "\(baseURL)/pages/\(pageId)")!
        let request = makeRequest(url: url, method: "GET")
        let data = try await perform(request)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func updatePage(pageId: String, properties: [String: Any]) async throws {
        let url = URL(string: "\(baseURL)/pages/\(pageId)")!
        var request = makeRequest(url: url, method: "PATCH")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["properties": properties])
        _ = try await perform(request)
    }

    // MARK: - Helpers

    func makeRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(notionVersion, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    func perform(_ request: URLRequest) async throws -> Data {
        guard !apiKey.isEmpty else { throw NotionError.notConfigured }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NotionError.apiError(http.statusCode, message)
        }
        return data
    }

    // MARK: - Block builders

    static func heading(_ level: Int, _ text: String, color: String = "default") -> [String: Any] {
        let type = "heading_\(level)"
        return ["object": "block", "type": type, type: ["rich_text": richText(text), "color": color]]
    }

    static func paragraph(_ text: String, color: String = "default") -> [String: Any] {
        ["object": "block", "type": "paragraph", "paragraph": ["rich_text": richText(text), "color": color]]
    }

    static func toDo(_ text: String, checked: Bool = false, color: String = "default") -> [String: Any] {
        ["object": "block", "type": "to_do", "to_do": ["rich_text": richText(text), "checked": checked, "color": color]]
    }

    static func divider() -> [String: Any] {
        ["object": "block", "type": "divider", "divider": [:]]
    }

    static func callout(_ emoji: String, _ text: String, color: String = "default") -> [String: Any] {
        ["object": "block", "type": "callout", "callout": [
            "rich_text": richText(text),
            "icon": ["type": "emoji", "emoji": emoji],
            "color": color
        ]]
    }

    static func callout(_ emoji: String, richTextItems: [[String: Any]], color: String = "default") -> [String: Any] {
        ["object": "block", "type": "callout", "callout": [
            "rich_text": richTextItems,
            "icon": ["type": "emoji", "emoji": emoji],
            "color": color
        ]]
    }

    static func bulletedListItem(_ text: String, color: String = "default") -> [String: Any] {
        ["object": "block", "type": "bulleted_list_item", "bulleted_list_item": [
            "rich_text": richText(text),
            "color": color
        ]]
    }

    static func columnList(left: [[String: Any]], right: [[String: Any]]) -> [String: Any] {
        let leftCol: [String: Any] = ["object": "block", "type": "column", "column": ["children": left] as [String: Any]]
        let rightCol: [String: Any] = ["object": "block", "type": "column", "column": ["children": right] as [String: Any]]
        return ["object": "block", "type": "column_list", "column_list": ["children": [leftCol, rightCol]] as [String: Any]]
    }

    static func richTextMention(pageId: String) -> [String: Any] {
        ["type": "mention", "mention": ["type": "page", "page": ["id": pageId]]]
    }

    static func richText(_ text: String) -> [[String: Any]] {
        [["type": "text", "text": ["content": text]]]
    }

    static func plainText(from richText: Any?) -> String {
        guard let items = richText as? [[String: Any]] else { return "" }
        return items.compactMap { $0["plain_text"] as? String }.joined()
    }
}
