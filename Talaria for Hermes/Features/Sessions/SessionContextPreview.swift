import SwiftUI

struct SessionContextPreview: View {
    let session: Session
    let isPinned: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            header

            if let preview = session.preview?.trimmingCharacters(in: .whitespacesAndNewlines), !preview.isEmpty {
                Text(preview)
                    .font(.body)
                    .lineLimit(4)
                    .foregroundStyle(.secondary)
            }

            metrics
        }
        .padding(Spacing.l)
        .frame(minWidth: 260, idealWidth: 320, maxWidth: 360, alignment: .leading)
        .background(.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Text(session.displayTitle)
                    .font(.headline)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isPinned {
                    Image(systemName: "pin.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Pinned")
                }
            }

            Label(session.displayModelID, systemImage: "cpu")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var metrics: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if let date = session.lastActiveDate {
                Label {
                    Text(date, format: .relative(presentation: .named, unitsStyle: .wide))
                } icon: {
                    Image(systemName: "clock")
                }
            }

            if let messageCount = session.messageCount {
                Label("^[\(messageCount) message](inflect: true)", systemImage: "bubble.left.and.bubble.right")
            }

            if let toolCallCount = session.toolCallCount, toolCallCount > 0 {
                Label("^[\(toolCallCount) tool call](inflect: true)", systemImage: "wrench.and.screwdriver")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}
