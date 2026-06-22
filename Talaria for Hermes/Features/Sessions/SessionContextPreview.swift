import SwiftUI

/// Context-menu preview that mirrors the chat view for a session: a slim title bar
/// over the tail of the conversation rendered as native chat bubbles.
///
/// Messages come from the local persistence cache (passed in by the list), so the
/// preview appears instantly with no network fetch — and, crucially, previewing a
/// session never triggers a load or run recovery the way mounting the real ChatView
/// would. Falls back to the server-provided last-message snippet when a session has
/// no locally cached history yet.
struct SessionContextPreview: View {
    let session: Session
    let messages: [TimelineMessage]
    let isPinned: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
        }
        .frame(width: 320)
        .background(.background)
    }

    // MARK: - Header (mimics the chat nav bar)

    private var header: some View {
        HStack(spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                Label(session.displayModelID, systemImage: "cpu")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Spacing.s)
            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Pinned")
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
    }

    // MARK: - Transcript

    @ViewBuilder
    private var transcript: some View {
        let bubbles = previewBubbles
        if bubbles.isEmpty {
            fallback
        } else {
            VStack(spacing: Spacing.s) {
                ForEach(bubbles) { bubble in
                    bubbleRow(bubble)
                }
            }
            .padding(Spacing.l)
        }
    }

    private func bubbleRow(_ bubble: PreviewBubble) -> some View {
        HStack(spacing: 0) {
            if bubble.isUser { Spacer(minLength: 40) }
            styled(bubble.text)
                .font(.subheadline)
                .lineLimit(6)
                .multilineTextAlignment(.leading)
                .foregroundStyle(bubble.isUser ? Color.white : Color.primary)
                .padding(.horizontal, Spacing.m)
                .padding(.vertical, Spacing.s)
                .background(
                    bubble.isUser ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.fill.tertiary),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
            if !bubble.isUser { Spacer(minLength: 40) }
        }
    }

    private var fallback: some View {
        HStack(spacing: 0) {
            styled(session.preview?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "No messages yet")
                .font(.subheadline)
                .lineLimit(6)
                .foregroundStyle(.primary)
                .padding(.horizontal, Spacing.m)
                .padding(.vertical, Spacing.s)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Spacer(minLength: 40)
        }
        .padding(Spacing.l)
    }

    // MARK: - Data

    private struct PreviewBubble: Identifiable {
        let id: UUID
        let isUser: Bool
        let text: String
    }

    /// The last few user/assistant messages with visible text, oldest-first so the
    /// most recent sits at the bottom like an opened chat.
    private var previewBubbles: [PreviewBubble] {
        messages
            .filter { $0.message.role == "user" || $0.message.role == "assistant" }
            .compactMap { msg -> PreviewBubble? in
                guard let text = msg.message.content?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { return nil }
                return PreviewBubble(id: msg.localID, isUser: msg.message.role == "user", text: text)
            }
            .suffix(5)
            .map { $0 }
    }

    /// Light inline-markdown styling so bold/code in the preview read like the chat.
    private func styled(_ text: String) -> Text {
        if let attr = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attr)
        }
        return Text(text)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
