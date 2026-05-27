import SwiftUI

struct MenuBarView: View {
    @ObservedObject private var setup = WorkspaceSetup.shared
    @ObservedObject private var linking = LinkingManager.shared
    @State private var selectedTab: Tab = .today
    @State private var isScanning = false
    @Environment(\.openSettings) private var openSettings

    private enum Tab { case today, links }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            tabContent
        }
        .frame(width: 300)
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton(label: "Today", tab: .today, badge: nil)
            tabButton(label: "🔗 Links", tab: .links,
                      badge: linking.pendingLinks.isEmpty ? nil : linking.pendingLinks.count)
        }
    }

    private func tabButton(label: String, tab: Tab, badge: Int?) -> some View {
        Button {
            selectedTab = tab
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 5) {
                    Text(label)
                        .font(.system(size: 12, weight: selectedTab == tab ? .semibold : .regular))
                        .foregroundStyle(selectedTab == tab ? .primary : .secondary)

                    if let badge, badge > 0 {
                        Text("\(badge)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.blue)
                            .clipShape(Capsule())
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)

                Rectangle()
                    .fill(selectedTab == tab ? Color.primary : Color.clear)
                    .frame(height: 2)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tab content

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .today:
            todayTab
        case .links:
            LinksView()
        }
    }

    private var todayTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuRow(icon: "arrow.up.right.square", label: "Open Today") {
                openToday()
            }
            .disabled(!setup.isComplete)

            thinDivider

            MenuRow(icon: "arrow.clockwise", label: "Refresh Projects") {
                Task { await TodayPageManager.shared.refreshActiveProjects() }
            }
            .disabled(!setup.isComplete)

            MenuRow(icon: "calendar", label: "Refresh Schedule") {
                Task { await TodayPageManager.shared.refreshSchedule() }
            }
            .disabled(!setup.isComplete)

            MenuRow(icon: "sparkle.magnifyingglass",
                    label: isScanning ? "Scanning…" : "Scan Notes") {
                Task {
                    isScanning = true
                    await LinkingManager.shared.checkForNewNotes(onDemand: true)
                    isScanning = false
                }
            }
            .disabled(!setup.isComplete || isScanning)

            thinDivider

            MenuRow(icon: "circle.hexagongrid.fill", label: "Knowledge Graph") {
                GraphWindowManager.shared.open()
            }
            .disabled(!setup.isComplete)

            thinDivider

            MenuRow(icon: "gearshape", label: "Settings") {
                openSettings()
                NSApp.activate(ignoringOtherApps: true)
            }

            MenuRow(icon: "power", label: "Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.vertical, 4)
    }

    private var thinDivider: some View {
        Divider()
            .padding(.vertical, 4)
            .padding(.horizontal, 12)
    }

    // MARK: - Helpers

    private func openToday() {
        let pageId = UserDefaults.shared.string(forKey: "hivemind.todayPageId") ?? ""
        guard !pageId.isEmpty else { return }
        let cleanId = pageId.replacingOccurrences(of: "-", with: "")
        if let url = URL(string: "notion://www.notion.so/\(cleanId)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Menu Row

private struct MenuRow: View {
    let icon: String
    let label: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 16)
                Text(label)
                    .font(.system(size: 13))
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .frame(maxWidth: .infinity)
            .background(isHovered ? Color.primary.opacity(0.07) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
