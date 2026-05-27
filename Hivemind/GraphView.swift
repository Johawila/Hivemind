import SwiftUI
import AppKit

// MARK: - Window Manager

class GraphWindowManager {
    static let shared = GraphWindowManager()
    private var window: NSWindow?

    func open() {
        if window == nil || !(window?.isVisible ?? false) {
            let hosting = NSHostingView(rootView: GraphView())
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 980, height: 740),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            w.title = "Knowledge Graph"
            w.contentView = hosting
            w.backgroundColor = NSColor(red: 0.04, green: 0.05, blue: 0.10, alpha: 1)
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Scroll Pan Capture

struct ScrollPanCapture: NSViewRepresentable {
    let onScroll: (CGFloat, CGFloat) -> Void
    let onMagnify: (CGFloat) -> Void

    func makeNSView(context: Context) -> _ScrollView {
        _ScrollView(onScroll: onScroll, onMagnify: onMagnify)
    }
    func updateNSView(_ nsView: _ScrollView, context: Context) {}

    class _ScrollView: NSView {
        let onScroll: (CGFloat, CGFloat) -> Void
        let onMagnify: (CGFloat) -> Void
        private var scrollMonitor: Any?
        private var magnifyMonitor: Any?

        init(onScroll: @escaping (CGFloat, CGFloat) -> Void, onMagnify: @escaping (CGFloat) -> Void) {
            self.onScroll = onScroll
            self.onMagnify = onMagnify
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitors()
            guard window != nil else { return }
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window == self.window else { return event }
                self.onScroll(event.scrollingDeltaX * 1.5, event.scrollingDeltaY * 1.5)
                return nil
            }
            magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
                guard let self, event.window == self.window else { return event }
                self.onMagnify(event.magnification)
                return nil
            }
            updateTrackingAreas()
        }

        // Make the window key on hover so pinch-zoom works after focus loss (e.g. opening Notion)
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach { removeTrackingArea($0) }
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                owner: self,
                userInfo: nil
            ))
        }

        override func mouseEntered(with event: NSEvent) {
            window?.makeKey()
        }

        private func removeMonitors() {
            if let m = scrollMonitor  { NSEvent.removeMonitor(m); scrollMonitor  = nil }
            if let m = magnifyMonitor { NSEvent.removeMonitor(m); magnifyMonitor = nil }
        }

        deinit { removeMonitors() }
    }
}

// MARK: - Graph View

struct GraphView: View {
    @StateObject private var vm = GraphViewModel()
    @State private var selectedEdgeId: String? = nil
    @State private var hasLoaded = false
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var lastPanOffset: CGSize = .zero
    @State private var canvasSize: CGSize = .zero

    private let bg = Color(red: 0.04, green: 0.05, blue: 0.10)
    private let clusterThreshold: CGFloat = 0.65

    /// 0 = fully expanded (individual nodes), 1 = fully clustered
    private var clusterBlend: CGFloat {
        let zone: CGFloat = 0.18
        return min(1, max(0, (clusterThreshold + zone * 0.5 - scale) / zone))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                bg.ignoresSafeArea()

                ScrollPanCapture(
                    onScroll: { dx, dy in
                        panOffset = CGSize(width: panOffset.width + dx, height: panOffset.height + dy)
                        lastPanOffset = panOffset
                    },
                    onMagnify: { delta in
                        scale = max(0.25, min(4.0, scale * (1 + delta)))
                        lastScale = scale
                    }
                )
                .allowsHitTesting(true)

                if vm.isLoading {
                    ProgressView().tint(.white)
                } else if vm.nodes.isEmpty {
                    emptyState
                } else {
                    starField.frame(width: geo.size.width, height: geo.size.height)

                    graphContent(size: geo.size)
                        .scaleEffect(scale, anchor: .center)
                        .offset(panOffset)

                    minimapView(canvasSize: geo.size).padding(14)

                    zoomControls
                        .padding(14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)

                    legend
                        .padding(14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .onAppear {
                canvasSize = geo.size
                guard !hasLoaded else { return }
                hasLoaded = true
                Task { await vm.load(canvasSize: geo.size) }
            }
            .onChange(of: geo.size) { newSize in canvasSize = newSize }
        }
        .frame(minWidth: 600, minHeight: 500)
        .onDisappear { vm.stopSimulation() }
    }

    // MARK: - Star field

    private var starField: some View {
        let size = canvasSize == .zero
            ? CGSize(width: NSScreen.main?.frame.width ?? 800, height: NSScreen.main?.frame.height ?? 600)
            : canvasSize

        return Canvas { context, _ in
            for (i, pos) in vm.starPositions.enumerated() {
                let hash = i * 2654435761
                let radius: CGFloat = 0.8 + CGFloat(hash % 100) / 100.0 * 0.7
                let opacity = 0.12 + CGFloat((hash >> 4) % 100) / 100.0 * 0.18
                let rect = CGRect(x: pos.x - radius, y: pos.y - radius, width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(opacity)))
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    // MARK: - Graph content

    private func graphContent(size: CGSize) -> some View {
        let blend = clusterBlend
        let colorMap = Dictionary(uniqueKeysWithValues: vm.visibleNodes.map { ($0.id, $0.color) })

        return ZStack {
            // Edge canvas
            Canvas { context, _ in
                let effectivePos: (GraphNode) -> CGPoint = { node in
                    guard blend > 0,
                          let cid = vm.clusterIdForNode(node.id),
                          let cluster = vm.clusters.first(where: { $0.id == cid }) else {
                        return node.position
                    }
                    return CGPoint(
                        x: node.position.x * (1 - blend) + cluster.centroid.x * blend,
                        y: node.position.y * (1 - blend) + cluster.centroid.y * blend
                    )
                }

                for edge in vm.visibleEdges {
                    guard let source = vm.visibleNodes.first(where: { $0.id == edge.sourceId }),
                          let target = vm.visibleNodes.first(where: { $0.id == edge.targetId }) else { continue }

                    if edge.isPending {
                        var path = Path()
                        path.move(to: source.position)
                        path.addLine(to: target.position)
                        context.stroke(path, with: .color(.orange.opacity(0.45)),
                                       style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        continue
                    }

                    let srcCluster = vm.clusterIdForNode(source.id)
                    let dstCluster = vm.clusterIdForNode(target.id)
                    let intraCluster = srcCluster != nil && srcCluster == dstCluster

                    let from = effectivePos(source)
                    let to = effectivePos(target)
                    let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)

                    let srcColor = colorMap[edge.sourceId] ?? .white
                    let dstColor = colorMap[edge.targetId] ?? .white
                    let opacity: CGFloat = intraCluster ? (1 - blend) * 0.50 : 0.55

                    if opacity < 0.01 { continue }

                    // Glow pass (wide, low opacity)
                    var glow = Path()
                    glow.move(to: from); glow.addLine(to: to)
                    context.stroke(glow, with: .color(srcColor.opacity(opacity * 0.14)),
                                   style: StrokeStyle(lineWidth: 4))

                    // Source-colour half
                    var p1 = Path()
                    p1.move(to: from); p1.addLine(to: mid)
                    context.stroke(p1, with: .color(srcColor.opacity(opacity)),
                                   style: StrokeStyle(lineWidth: 0.75))

                    // Target-colour half
                    var p2 = Path()
                    p2.move(to: mid); p2.addLine(to: to)
                    context.stroke(p2, with: .color(dstColor.opacity(opacity)),
                                   style: StrokeStyle(lineWidth: 0.75))
                }
            }

            // Pending edge action buttons (only when zoomed in enough)
            if blend < 0.5 {
                ForEach(vm.visibleEdges.filter { $0.isPending }) { edge in
                    pendingEdgeButton(edge: edge)
                }
            }

            // Cluster node blobs (fade in as blend → 1)
            if blend > 0.02 {
                ForEach(vm.clusters) { cluster in
                    clusterNodeView(cluster: cluster)
                        .opacity(Double(blend))
                }
            }

            // Individual nodes (fade out for clustered members as blend → 1, also fade for hidden types)
            ForEach(vm.nodes) { node in
                let hidden = vm.hiddenTypes.contains(node.nodeType)
                let inCluster = vm.clusterIdForNode(node.id) != nil
                let nodeOpacity = hidden ? 0.0 : Double(inCluster ? max(0, 1 - blend) : 1.0)
                nodeView(node: node)
                    .opacity(nodeOpacity)
                    .allowsHitTesting(nodeOpacity > 0.12)
                    .animation(.easeInOut(duration: 0.25), value: hidden)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    // MARK: - Cluster node view

    private func clusterNodeView(cluster: GraphCluster) -> some View {
        ZStack {
            Circle()
                .fill(cluster.color.opacity(0.05))
                .frame(width: cluster.radius * 3.8, height: cluster.radius * 3.8)
                .blur(radius: 14)

            Circle()
                .fill(cluster.color.opacity(0.12))
                .frame(width: cluster.radius * 2.6, height: cluster.radius * 2.6)
                .blur(radius: 9)

            Circle()
                .fill(cluster.color.opacity(0.22))
                .frame(width: cluster.radius * 1.6, height: cluster.radius * 1.6)
                .blur(radius: 4)

            Circle()
                .fill(LinearGradient(
                    colors: [cluster.color.opacity(0.85), cluster.color],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .frame(width: cluster.radius, height: cluster.radius)
                .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 0.5))

            Text("\(cluster.memberIds.count)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .shadow(color: .black, radius: 2)
        }
        .position(cluster.centroid)
        .onTapGesture {
            withAnimation(.spring(response: 0.65, dampingFraction: 0.90)) {
                scale = 1.0
                lastScale = scale
                panOffset = CGSize(
                    width: (canvasSize.width / 2 - cluster.centroid.x) * scale,
                    height: (canvasSize.height / 2 - cluster.centroid.y) * scale
                )
                lastPanOffset = panOffset
            }
        }
    }

    // MARK: - Node view

    private func nodeView(node: GraphNode) -> some View {
        ZStack {
            // Outer ambient glow
            Circle()
                .fill(node.color.opacity(0.06))
                .frame(width: node.radius * 2 + 20, height: node.radius * 2 + 20)
                .blur(radius: 10)

            // Inner glow ring
            Circle()
                .fill(node.color.opacity(0.14))
                .frame(width: node.radius * 2 + 8, height: node.radius * 2 + 8)
                .blur(radius: 5)

            // Main circle
            Circle()
                .fill(LinearGradient(
                    colors: [node.color.opacity(0.85), node.color],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .frame(width: node.radius * 2, height: node.radius * 2)
                .shadow(color: node.color.opacity(0.6), radius: 5, x: 0, y: 2)
                .overlay(Circle().stroke(.white.opacity(0.22), lineWidth: 0.5))

            // Icon
        Image(systemName: node.nodeType.icon)
            .font(.system(size: max(10, node.radius * 0.55), weight: .semibold))
            .foregroundStyle(.white.opacity(0.92))

        // Title label below the circle — offset doesn't affect ZStack's layout frame
        // so .position() still centers on node.position correctly
        if node.radius * scale > 14 {
            Text(node.title)
                .font(.system(size: max(9, node.radius * 0.32), weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(width: max(64, node.radius * 3.5))
                .offset(y: node.radius + 13)
        }
        }
        .position(node.position)
        .onTapGesture { openInNotion(pageId: node.id) }
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in vm.dragNode(id: node.id, to: value.location) }
                .onEnded { _ in vm.releaseNode(id: node.id) }
        )
    }

    // MARK: - Pending edge button

    @ViewBuilder
    private func pendingEdgeButton(edge: GraphEdge) -> some View {
        if let source = vm.nodes.first(where: { $0.id == edge.sourceId }),
           let target = vm.nodes.first(where: { $0.id == edge.targetId }) {
            let mid = CGPoint(
                x: (source.position.x + target.position.x) / 2,
                y: (source.position.y + target.position.y) / 2
            )
            Button {
                selectedEdgeId = selectedEdgeId == edge.id ? nil : edge.id
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.orange.opacity(0.22))
                        .frame(width: 24, height: 24)
                        .blur(radius: 4)
                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(.orange)
                        .background(
                            Circle()
                                .fill(Color(red: 0.04, green: 0.05, blue: 0.10))
                                .padding(-3)
                        )
                }
            }
            .buttonStyle(.plain)
            .position(mid)
            .popover(isPresented: Binding(
                get: { selectedEdgeId == edge.id },
                set: { if !$0 { selectedEdgeId = nil } }
            )) {
                if let link = edge.pendingLink {
                    PendingLinkPopover(link: link) {
                        Task {
                            await LinkingManager.shared.approveLink(link)
                            selectedEdgeId = nil
                            await vm.load(canvasSize: vm.canvasSize)
                        }
                    } onDismiss: {
                        LinkingManager.shared.dismissLink(link)
                        selectedEdgeId = nil
                        Task { await vm.load(canvasSize: vm.canvasSize) }
                    }
                }
            }
        }
    }

    // MARK: - Legend

    private var legend: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach([NodeType.note, .task, .project, .person, .team], id: \.rawValue) { type in
                let hidden = vm.hiddenTypes.contains(type)
                Button { withAnimation(.easeInOut(duration: 0.25)) { vm.toggleType(type) } } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(hidden ? Color.white.opacity(0.15) : type.baseColor)
                            .frame(width: 8, height: 8)
                            .shadow(color: type.baseColor.opacity(hidden ? 0 : 0.6), radius: 3)
                        Text(type.rawValue.capitalized)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(hidden ? .white.opacity(0.25) : .white.opacity(0.75))
                        Spacer()
                        if hidden {
                            Image(systemName: "eye.slash")
                                .font(.system(size: 8))
                                .foregroundStyle(.white.opacity(0.25))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .frame(width: 100)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.07), lineWidth: 1))
    }

    // MARK: - Minimap

    private func minimapView(canvasSize: CGSize) -> some View {
        let mw: CGFloat = 148
        let mh: CGFloat = 108
        let sx = mw / canvasSize.width
        let sy = mh / canvasSize.height
        let cw = canvasSize.width
        let ch = canvasSize.height
        let blend = clusterBlend

        let vpX = (cw / 2 - (cw / 2 + panOffset.width) / scale) * sx
        let vpY = (ch / 2 - (ch / 2 + panOffset.height) / scale) * sy
        let vpW = (cw / scale) * sx
        let vpH = (ch / scale) * sy
        let clampedVp = CGRect(x: vpX, y: vpY, width: vpW, height: vpH)
            .intersection(CGRect(x: 0, y: 0, width: mw, height: mh))

        let minimapDrag = DragGesture(minimumDistance: 0)
            .onChanged { value in
                panOffset = CGSize(
                    width: scale * (canvasSize.width / 2 - value.location.x * canvasSize.width / mw),
                    height: scale * (canvasSize.height / 2 - value.location.y * canvasSize.height / mh)
                )
            }
            .onEnded { _ in lastPanOffset = panOffset }

        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.black.opacity(0.55))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(0.10), lineWidth: 1))

            Canvas { context, _ in
                // Edges (always draw thin, de-emphasised)
                for edge in vm.visibleEdges.filter({ !$0.isPending }) {
                    guard let src = vm.visibleNodes.first(where: { $0.id == edge.sourceId }),
                          let dst = vm.visibleNodes.first(where: { $0.id == edge.targetId }) else { continue }
                    var p = Path()
                    p.move(to: CGPoint(x: src.position.x * sx, y: src.position.y * sy))
                    p.addLine(to: CGPoint(x: dst.position.x * sx, y: dst.position.y * sy))
                    context.stroke(p, with: .color(.white.opacity(0.12)), lineWidth: 0.5)
                }

                // Individual nodes (fade out when clustered)
                for node in vm.visibleNodes {
                    let inCluster = vm.clusterIdForNode(node.id) != nil
                    let nodeOpacity = inCluster ? Double(max(0, 1 - blend)) : 1.0
                    let r: CGFloat = max(2.2, node.radius * sx * 2.0)
                    let rect = CGRect(x: node.position.x * sx - r / 2,
                                      y: node.position.y * sy - r / 2,
                                      width: r, height: r)
                    context.fill(Path(ellipseIn: rect), with: .color(node.color.opacity(nodeOpacity)))
                }

                // Cluster blobs (fade in when clustered)
                if blend > 0 {
                    for cluster in vm.clusters {
                        let r: CGFloat = max(3.5, cluster.radius * sx * 2.2)
                        let rect = CGRect(x: cluster.centroid.x * sx - r / 2,
                                          y: cluster.centroid.y * sy - r / 2,
                                          width: r, height: r)
                        context.fill(Path(ellipseIn: rect), with: .color(cluster.color.opacity(Double(blend))))
                    }
                }

                // Viewport indicator
                if !clampedVp.isNull && !clampedVp.isEmpty {
                    context.fill(Path(clampedVp), with: .color(.white.opacity(0.05)))
                    context.stroke(Path(clampedVp), with: .color(.white.opacity(0.50)), lineWidth: 1)
                }
            }
            .frame(width: mw, height: mh)
            .clipShape(RoundedRectangle(cornerRadius: 9))

            Image(systemName: "hand.point.up.left")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .padding(5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .frame(width: mw, height: mh)
        .gesture(minimapDrag)
    }

    // MARK: - Zoom controls

    private var zoomControls: some View {
        HStack(spacing: 4) {
            zoomButton(icon: "minus") {
                withAnimation(.easeInOut(duration: 0.18)) {
                    scale = max(0.25, scale / 1.35)
                    lastScale = scale
                }
            }
            Text("\(Int(scale * 100))%")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 42)
            zoomButton(icon: "plus") {
                withAnimation(.easeInOut(duration: 0.18)) {
                    scale = min(4.0, scale * 1.35)
                    lastScale = scale
                }
            }
            Divider().frame(height: 14).padding(.horizontal, 2)
            zoomButton(icon: "arrow.up.left.and.arrow.down.right") {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    scale = 1.0; lastScale = 1.0
                    panOffset = .zero; lastPanOffset = .zero
                }
            }
            Divider().frame(height: 14).padding(.horizontal, 2)
            Button {
                Task { await vm.toggleCompleted(canvasSize: canvasSize) }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: vm.showCompletedTasks ? "checkmark.square.fill" : "square")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Done")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(vm.showCompletedTasks ? .primary : .secondary)
                .frame(height: 26)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.08), lineWidth: 1))
    }

    private func zoomButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "circle.hexagongrid")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("No data yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Run Setup in Settings, then add items to your Notion workspace.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
    }

    // MARK: - Helpers

    private func openInNotion(pageId: String) {
        guard !pageId.hasPrefix("test-") else { return }
        let cleanId = pageId.replacingOccurrences(of: "-", with: "")
        if let url = URL(string: "notion://www.notion.so/\(cleanId)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Pending link popover

struct PendingLinkPopover: View {
    let link: PendingLink
    let onApprove: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(link.noteATitle)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)

            HStack {
                Text("↕")
                Text("\(Int(link.confidence * 100))% match")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)

            Text(link.noteBTitle)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)

            Text(link.reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack(spacing: 8) {
                Button("Dismiss") { onDismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)

                Button("✓ Link") { onApprove() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
        }
        .padding(12)
        .frame(width: 220)
    }
}
