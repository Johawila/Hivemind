import SwiftUI

struct LinksView: View {
    @ObservedObject private var linking = LinkingManager.shared
    @State private var currentIndex = 0

    var body: some View {
        if linking.pendingLinks.isEmpty {
            emptyState
        } else {
            linkCard
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("No pending links")
                .foregroundStyle(.secondary)
                .padding(.top, 8)

            Button("Load Test Data") {
                linking.loadTestData()
                currentIndex = 0
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
            .font(.footnote)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
    }

    // MARK: - Link card

    private var linkCard: some View {
        let link = linking.pendingLinks[min(currentIndex, linking.pendingLinks.count - 1)]

        return VStack(alignment: .leading, spacing: 0) {
            noteRow(title: link.noteATitle, snippet: link.noteASnippet, noteId: link.noteAId)

            HStack {
                Rectangle()
                    .frame(height: 1)
                    .foregroundStyle(.separator)
                Text("\(Int(link.confidence * 100))% match")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Rectangle()
                    .frame(height: 1)
                    .foregroundStyle(.separator)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 12)

            noteRow(title: link.noteBTitle, snippet: link.noteBSnippet, noteId: link.noteBId)

            Text(link.reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 6)

            actionRow(link: link)

            Divider()

            paginationRow
        }
    }

    private func noteRow(title: String, snippet: String, noteId: String) -> some View {
        Button {
            openInNotion(pageId: noteId)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }

    private func actionRow(link: PendingLink) -> some View {
        HStack(spacing: 8) {
            Button("Dismiss") {
                linking.dismissLink(link)
                clampIndex()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Button("✓ Link") {
                Task { await linking.approveLink(link) }
                clampIndex()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(.blue)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var paginationRow: some View {
        HStack {
            Button("←") { if currentIndex > 0 { currentIndex -= 1 } }
                .buttonStyle(.plain)
                .foregroundStyle(currentIndex > 0 ? .primary : .quaternary)

            Spacer()

            Text("\(min(currentIndex + 1, linking.pendingLinks.count)) of \(linking.pendingLinks.count)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button("→") { if currentIndex < linking.pendingLinks.count - 1 { currentIndex += 1 } }
                .buttonStyle(.plain)
                .foregroundStyle(currentIndex < linking.pendingLinks.count - 1 ? .primary : .quaternary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Helpers

    private func clampIndex() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if linking.pendingLinks.isEmpty {
                currentIndex = 0
            } else {
                currentIndex = min(currentIndex, linking.pendingLinks.count - 1)
            }
        }
    }

    private func openInNotion(pageId: String) {
        guard !pageId.hasPrefix("test-") else { return }
        let cleanId = pageId.replacingOccurrences(of: "-", with: "")
        if let url = URL(string: "notion://www.notion.so/\(cleanId)") {
            NSWorkspace.shared.open(url)
        }
    }
}
