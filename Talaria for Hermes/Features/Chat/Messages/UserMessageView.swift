import SwiftUI

struct UserMessageView: View {
    let turn: ChatTurn

    var body: some View {
        HStack {
            Spacer(minLength: Spacing.xl)
            VStack(alignment: .trailing, spacing: Spacing.xs) {
                if let text = turn.userMessage.message.content, !text.isEmpty {
                    MarkdownText(source: text)
                        .padding(Spacing.m)
                        .background(Palette.user.opacity(0.18))
                        .clipShape(.rect(cornerRadius: Radii.large))
                }
                if turn.isSending {
                    HStack(spacing: Spacing.xs) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Sending…")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text(userDate, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var userDate: Date {
        turn.userMessage.message.timestamp.map { Date(timeIntervalSince1970: $0) } ?? Date.now
    }
}
