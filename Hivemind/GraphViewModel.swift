import Foundation
import SwiftUI
import Combine

// MARK: - Node type

enum NodeType: String {
    case note, task, project, person, team

    var icon: String {
        switch self {
        case .note:    return "doc.text.fill"
        case .task:    return "checkmark.square.fill"
        case .project: return "folder.fill"
        case .person:  return "person.fill"
        case .team:    return "person.3.fill"
        }
    }

    var baseColor: Color {
        switch self {
        case .note:    return Color(red: 0.38, green: 0.62, blue: 1.00)   // blue
        case .task:    return Color(red: 1.00, green: 0.65, blue: 0.20)   // amber
        case .project: return Color(red: 0.22, green: 0.88, blue: 0.60)   // green
        case .person:  return Color(red: 1.00, green: 0.38, blue: 0.45)   // coral
        case .team:    return Color(red: 0.80, green: 0.35, blue: 1.00)   // violet
        }
    }
}

// MARK: - Graph node

struct GraphNode: Identifiable {
    let id: String
    let title: String
    let tags: [String]
    let nodeType: NodeType
    var position: CGPoint
    var velocity: CGPoint = .zero
    var connectionCount: Int = 0
    var isPinned: Bool = false

    var radius: CGFloat {
        let base: CGFloat
        switch nodeType {
        case .team:    base = 20
        case .project: base = 18
        default:       base = 14
        }
        return base + CGFloat(min(connectionCount, 10)) * 2.0
    }

    var color: Color {
        switch nodeType {
        case .note:
            let palette: [Color] = [
                Color(red: 0.38, green: 0.62, blue: 1.00),
                Color(red: 0.20, green: 0.85, blue: 0.95),
                Color(red: 0.55, green: 0.70, blue: 1.00),
                Color(red: 0.25, green: 0.78, blue: 0.90),
                Color(red: 0.45, green: 0.55, blue: 0.98),
                Color(red: 0.30, green: 0.90, blue: 0.80),
            ]
            guard let first = tags.first else { return nodeType.baseColor }
            let hash = first.unicodeScalars.reduce(0) { $0 + Int($1.value) }
            return palette[hash % palette.count]
        default:
            return nodeType.baseColor
        }
    }
}

// MARK: - Graph edge

struct GraphEdge: Identifiable {
    let id: String
    let sourceId: String
    let targetId: String
    let isPending: Bool
    let pendingLink: PendingLink?
}

// MARK: - Graph cluster

struct GraphCluster: Identifiable {
    let id: String
    let memberIds: [String]
    var centroid: CGPoint
    var color: Color

    var radius: CGFloat {
        32 + CGFloat(min(memberIds.count, 30)) * 2.2
    }
}

// MARK: - View model

class GraphViewModel: ObservableObject {
    @Published var nodes: [GraphNode] = []
    @Published var edges: [GraphEdge] = []
    @Published var clusters: [GraphCluster] = []
    @Published var isLoading = false
    @Published var showCompletedTasks = false
    @Published var hiddenTypes: Set<NodeType> = []

    var visibleNodes: [GraphNode] {
        nodes.filter { !hiddenTypes.contains($0.nodeType) }
    }

    var visibleEdges: [GraphEdge] {
        let visibleIds = Set(visibleNodes.map { $0.id })
        return edges.filter { visibleIds.contains($0.sourceId) && visibleIds.contains($0.targetId) }
    }

    func toggleType(_ type: NodeType) {
        if hiddenTypes.contains(type) { hiddenTypes.remove(type) } else { hiddenTypes.insert(type) }
    }

    var canvasSize: CGSize = .zero
    var starPositions: [CGPoint] = []
    private var nodeToClusterId: [String: String] = [:]

    private var simulationTimer: Timer?
    private var stepCount = 0
    private let maxSteps = 400

    private let notion = NotionService.shared
    private var notesDbId:    String { UserDefaults.shared.string(forKey: "hivemind.notesDbId")    ?? "" }
    private var tasksDbId:    String { UserDefaults.shared.string(forKey: "hivemind.tasksDbId")    ?? "" }
    private var projectsDbId: String { UserDefaults.shared.string(forKey: "hivemind.projectsDbId") ?? "" }
    private var peopleDbId:   String { UserDefaults.shared.string(forKey: "hivemind.peopleDbId")   ?? "" }
    private var teamsDbId:    String { UserDefaults.shared.string(forKey: "hivemind.teamsDbId")    ?? "" }

    // MARK: - Public

    func load(canvasSize: CGSize) async {
        self.canvasSize = canvasSize
        await MainActor.run { isLoading = true }
        stopSimulation()

        // Fetch all entity types in parallel
        async let notesFetch    = safeQuery(notesDbId)
        async let tasksFetch    = safeQuery(tasksDbId, filter: showCompletedTasks ? nil : incompleteTasks)
        async let projectsFetch = safeQuery(projectsDbId)
        async let peopleFetch   = safeQuery(peopleDbId)
        async let teamsFetch    = safeQuery(teamsDbId)

        let (allNotes, allTasks, allProjects, allPeople, allTeams) =
            await (notesFetch, tasksFetch, projectsFetch, peopleFetch, teamsFetch)

        guard !allNotes.isEmpty || !allTasks.isEmpty || !allProjects.isEmpty
                || !allPeople.isEmpty || !allTeams.isEmpty else {
            await MainActor.run { isLoading = false }
            return
        }

        var nodeDict: [String: GraphNode] = [:]
        var newEdges: [GraphEdge] = []
        var seenEdges = Set<String>()

        func addEdge(a: String, b: String) {
            let key = [a, b].sorted().joined(separator: "—")
            if seenEdges.insert(key).inserted {
                newEdges.append(GraphEdge(id: key, sourceId: a, targetId: b, isPending: false, pendingLink: nil))
            }
        }

        // Notes + Note–Note links
        for note in allNotes {
            guard let id = note["id"] as? String else { continue }
            let props = note["properties"] as? [String: Any]
            let title = extractTitle(from: note)
            let tags = ((props?["Tags"] as? [String: Any])?["multi_select"] as? [[String: Any]])?
                .compactMap { $0["name"] as? String } ?? []
            nodeDict[id] = GraphNode(id: id, title: title, tags: tags, nodeType: .note, position: randomPosition())
            for linkId   in relations(in: props, key: "Links")   { addEdge(a: id, b: linkId) }
            for projId   in relations(in: props, key: "Project")  { addEdge(a: id, b: projId) }
            for personId in relations(in: props, key: "Person")   { addEdge(a: id, b: personId) }
        }

        // Teams
        for team in allTeams {
            guard let id = team["id"] as? String else { continue }
            nodeDict[id] = GraphNode(id: id, title: extractTitle(from: team), tags: [], nodeType: .team, position: randomPosition())
        }

        // Projects
        for project in allProjects {
            guard let id = project["id"] as? String else { continue }
            nodeDict[id] = GraphNode(id: id, title: extractTitle(from: project), tags: [], nodeType: .project, position: randomPosition())
        }

        // People + Person–Team edges
        for person in allPeople {
            guard let id = person["id"] as? String else { continue }
            nodeDict[id] = GraphNode(id: id, title: extractTitle(from: person), tags: [], nodeType: .person, position: randomPosition())
            let props = person["properties"] as? [String: Any]
            for teamId in relations(in: props, key: "Team") { addEdge(a: id, b: teamId) }
        }

        // Tasks + Task–Project and Task–Person edges
        for task in allTasks {
            guard let id = task["id"] as? String else { continue }
            nodeDict[id] = GraphNode(id: id, title: extractTitle(from: task), tags: [], nodeType: .task, position: randomPosition())
            let props = task["properties"] as? [String: Any]
            for projId   in relations(in: props, key: "Project") { addEdge(a: id, b: projId) }
            for personId in relations(in: props, key: "Person")  { addEdge(a: id, b: personId) }
        }

        // Pending note links
        for link in LinkingManager.shared.pendingLinks {
            newEdges.append(GraphEdge(
                id: "pending-\(link.id)",
                sourceId: link.noteAId,
                targetId: link.noteBId,
                isPending: true,
                pendingLink: link
            ))
        }

        // Drop edges where an endpoint has no node (e.g. archived items not fetched)
        let validIds = Set(nodeDict.keys)
        let validEdges = newEdges.filter { validIds.contains($0.sourceId) && validIds.contains($0.targetId) }

        var newNodes = Array(nodeDict.values)
        for i in newNodes.indices {
            newNodes[i].connectionCount = validEdges.filter {
                !$0.isPending && ($0.sourceId == newNodes[i].id || $0.targetId == newNodes[i].id)
            }.count
        }

        arrangeInitial(&newNodes)
        let generatedStars = generateStarPositions(canvasSize: canvasSize)

        await MainActor.run {
            self.nodes = newNodes
            self.edges = validEdges
            self.isLoading = false
            self.stepCount = 0
            self.starPositions = generatedStars
            self.recomputeClusters()
        }

        startSimulation()
    }

    func toggleCompleted(canvasSize: CGSize) async {
        showCompletedTasks.toggle()
        await load(canvasSize: canvasSize)
    }

    func dragNode(id: String, to position: CGPoint) {
        guard let i = nodes.firstIndex(where: { $0.id == id }) else { return }
        nodes[i].position = position
        nodes[i].velocity = .zero
        nodes[i].isPinned = true
        if simulationTimer == nil { startSimulation() }
    }

    func releaseNode(id: String) {
        guard let i = nodes.firstIndex(where: { $0.id == id }) else { return }
        nodes[i].isPinned = false
    }

    func stopSimulation() {
        simulationTimer?.invalidate()
        simulationTimer = nil
    }

    func clusterIdForNode(_ nodeId: String) -> String? {
        nodeToClusterId[nodeId]
    }

    // MARK: - Simulation

    private func startSimulation() {
        stopSimulation()
        stepCount = 0
        simulationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.simulationStep()
        }
    }

    private func simulationStep() {
        guard !nodes.isEmpty else { stopSimulation(); return }
        stepCount += 1

        let repulsion: CGFloat = 9000
        let springK: CGFloat = 0.05
        let restLength: CGFloat = 110
        let gravity: CGFloat = 0.014
        let damping: CGFloat = 0.84
        // Connected cluster pulls toward left-center to leave room for isolated groups on right
        let connectedCenter = CGPoint(x: canvasSize.width * 0.38, y: canvasSize.height * 0.50)
        let padding: CGFloat = 70

        for i in nodes.indices {
            guard !nodes[i].isPinned else { continue }
            var fx: CGFloat = 0
            var fy: CGFloat = 0

            for j in nodes.indices where i != j {
                let dx = nodes[i].position.x - nodes[j].position.x
                let dy = nodes[i].position.y - nodes[j].position.y
                let d2 = max(dx * dx + dy * dy, 100)
                let d = sqrt(d2)
                // Same-type isolated nodes use moderate repulsion — enough to space out but
                // still held together by the shared anchor gravity
                let bothIsolatedSameType = nodes[i].connectionCount == 0
                    && nodes[j].connectionCount == 0
                    && nodes[i].nodeType == nodes[j].nodeType
                let effectiveRepulsion = bothIsolatedSameType ? repulsion * 0.50 : repulsion
                let f = effectiveRepulsion / d2
                fx += f * dx / d
                fy += f * dy / d
            }

            for edge in edges where !edge.isPending {
                guard edge.sourceId == nodes[i].id || edge.targetId == nodes[i].id else { continue }
                let otherId = edge.sourceId == nodes[i].id ? edge.targetId : edge.sourceId
                guard let other = nodes.first(where: { $0.id == otherId }) else { continue }
                let dx = other.position.x - nodes[i].position.x
                let dy = other.position.y - nodes[i].position.y
                let d = max(sqrt(dx * dx + dy * dy), 1)
                let f = springK * (d - restLength)
                fx += f * dx / d
                fy += f * dy / d
            }

            if nodes[i].connectionCount == 0 {
                // Isolated nodes: attract to their type-specific anchor on the right side
                let anchor = isolatedTypeAnchor(for: nodes[i].nodeType)
                fx += 0.028 * (anchor.x - nodes[i].position.x)
                fy += 0.028 * (anchor.y - nodes[i].position.y)
            } else {
                fx += gravity * (connectedCenter.x - nodes[i].position.x)
                fy += gravity * (connectedCenter.y - nodes[i].position.y)
            }

            nodes[i].velocity.x = (nodes[i].velocity.x + fx) * damping
            nodes[i].velocity.y = (nodes[i].velocity.y + fy) * damping

            let maxW = max(canvasSize.width - padding, padding)
            let maxH = max(canvasSize.height - padding, padding)
            nodes[i].position.x = min(max(nodes[i].position.x + nodes[i].velocity.x, padding), maxW)
            nodes[i].position.y = min(max(nodes[i].position.y + nodes[i].velocity.y, padding), maxH)
        }

        if stepCount % 30 == 0 { recomputeClusters() }

        if stepCount >= maxSteps || isSettled() {
            // Pin isolated nodes so they don't jitter when drags restart the simulation
            for i in nodes.indices where nodes[i].connectionCount == 0 {
                nodes[i].isPinned = true
            }
            stopSimulation()
        }
    }

    // MARK: - Clustering

    private func recomputeClusters() {
        let confirmedEdges = edges.filter { !$0.isPending }

        var adjacency: [String: Set<String>] = [:]
        for node in nodes { adjacency[node.id] = [] }
        for edge in confirmedEdges {
            adjacency[edge.sourceId, default: []].insert(edge.targetId)
            adjacency[edge.targetId, default: []].insert(edge.sourceId)
        }

        var visited = Set<String>()
        var components: [[String]] = []

        for node in nodes {
            guard !visited.contains(node.id) else { continue }
            var component: [String] = []
            var queue: [String] = [node.id]
            visited.insert(node.id)
            while !queue.isEmpty {
                let current = queue.removeFirst()
                component.append(current)
                for neighbor in adjacency[current, default: []] where !visited.contains(neighbor) {
                    visited.insert(neighbor)
                    queue.append(neighbor)
                }
            }
            components.append(component)
        }

        var newClusters: [GraphCluster] = []
        var newNodeToClusterId: [String: String] = [:]

        for component in components where component.count >= 3 {
            let clusterId = component.sorted().joined(separator: ",")
            let memberNodes = component.compactMap { id in nodes.first(where: { $0.id == id }) }
            let sumX = memberNodes.reduce(CGFloat(0)) { $0 + $1.position.x }
            let sumY = memberNodes.reduce(CGFloat(0)) { $0 + $1.position.y }
            let centroid = memberNodes.isEmpty ? CGPoint.zero
                : CGPoint(x: sumX / CGFloat(memberNodes.count), y: sumY / CGFloat(memberNodes.count))
            let color = nodes.first(where: { component.contains($0.id) })?.color
                ?? Color(red: 0.35, green: 0.40, blue: 0.55)

            newClusters.append(GraphCluster(id: clusterId, memberIds: component, centroid: centroid, color: color))
            for nodeId in component { newNodeToClusterId[nodeId] = clusterId }
        }

        clusters = newClusters
        nodeToClusterId = newNodeToClusterId
    }

    // MARK: - Private helpers

    private func safeQuery(_ dbId: String, filter: [String: Any]? = nil) async -> [[String: Any]] {
        guard !dbId.isEmpty else { return [] }
        return (try? await notion.queryDatabase(databaseId: dbId, filter: filter)) ?? []
    }

    private func extractTitle(from item: [String: Any]) -> String {
        let props = item["properties"] as? [String: Any]
        if let t = ((props?["Name"] as? [String: Any])?["title"] as? [[String: Any]])?.first?["plain_text"] as? String,
           !t.isEmpty { return t }
        return "Untitled"
    }

    private func relations(in props: [String: Any]?, key: String) -> [String] {
        ((props?[key] as? [String: Any])?["relation"] as? [[String: Any]])?
            .compactMap { $0["id"] as? String } ?? []
    }

    private var incompleteTasks: [String: Any] {
        ["property": "Done", "checkbox": ["equals": false]]
    }

    private func isSettled() -> Bool {
        nodes.allSatisfy { abs($0.velocity.x) < 0.3 && abs($0.velocity.y) < 0.3 }
    }

    /// Connected nodes cluster left-center grouped by type; isolated nodes pre-position near their right-side type anchors.
    private func arrangeInitial(_ nodes: inout [GraphNode]) {
        guard !nodes.isEmpty else { return }
        let cx = canvasSize.width * 0.38
        let cy = canvasSize.height * 0.50
        let typeOrder: [NodeType] = [.team, .project, .person, .note, .task]

        let connectedIndices = nodes.indices.filter { nodes[$0].connectionCount > 0 }
        let isolatedIndices  = nodes.indices.filter { nodes[$0].connectionCount == 0 }

        // Connected nodes — grouped by type, placed in left-center inner zone
        var byType: [NodeType: [Int]] = [:]
        for idx in connectedIndices { byType[nodes[idx].nodeType, default: []].append(idx) }
        let activeTypes = typeOrder.filter { !(byType[$0]?.isEmpty ?? true) }
        let innerRadius = min(canvasSize.width, canvasSize.height) * 0.22

        for (gi, type) in activeTypes.enumerated() {
            guard let indices = byType[type] else { continue }
            let groupAngle = CGFloat(gi) / CGFloat(max(activeTypes.count, 1)) * 2 * .pi - .pi / 2
            let gx = cx + innerRadius * cos(groupAngle)
            let gy = cy + innerRadius * sin(groupAngle)
            let subR = min(innerRadius * 0.45, 40 + CGFloat(indices.count) * 3)
            for (j, idx) in indices.enumerated() {
                let angle = CGFloat(j) / CGFloat(max(indices.count, 1)) * 2 * .pi
                nodes[idx].position = CGPoint(x: gx + subR * cos(angle), y: gy + subR * sin(angle))
            }
        }

        // Isolated nodes — grid layout around each type anchor so nodes start with proper spacing
        var byTypeIsolated: [NodeType: [Int]] = [:]
        for idx in isolatedIndices { byTypeIsolated[nodes[idx].nodeType, default: []].append(idx) }
        for (type, indices) in byTypeIsolated {
            let anchor = isolatedTypeAnchor(for: type)
            let cols = max(1, Int(ceil(sqrt(Double(indices.count)))))
            let spacing: CGFloat = 50
            for (j, idx) in indices.enumerated() {
                let row = j / cols
                let col = j % cols
                let rowCount = min(cols, indices.count - row * cols)
                let offsetX = (CGFloat(col) - CGFloat(rowCount - 1) / 2.0) * spacing
                let offsetY = (CGFloat(row) - CGFloat((indices.count - 1) / cols) / 2.0) * spacing
                nodes[idx].position = CGPoint(x: anchor.x + offsetX, y: anchor.y + offsetY)
            }
        }
    }

    /// Right-side anchor position for isolated nodes of a given type.
    /// Types are distributed vertically so each type group sits in its own row.
    private func isolatedTypeAnchor(for nodeType: NodeType) -> CGPoint {
        let typeOrder: [NodeType] = [.team, .project, .person, .note, .task]
        let idx = CGFloat(typeOrder.firstIndex(of: nodeType) ?? 0)
        let count = CGFloat(typeOrder.count)
        let x = canvasSize.width * 0.80
        let yPad = canvasSize.height * 0.12
        let y = yPad + (canvasSize.height - 2 * yPad) * idx / (count - 1)
        return CGPoint(x: x, y: y)
    }

    private func randomPosition() -> CGPoint {
        let w = max(canvasSize.width, 200)
        let h = max(canvasSize.height, 200)
        return CGPoint(x: CGFloat.random(in: 80...(w - 80)), y: CGFloat.random(in: 80...(h - 80)))
    }

    private func generateStarPositions(canvasSize: CGSize) -> [CGPoint] {
        let w = max(canvasSize.width, 800)
        let h = max(canvasSize.height, 600)
        return (0..<180).map { _ in CGPoint(x: CGFloat.random(in: 0...w), y: CGFloat.random(in: 0...h)) }
    }
}
