import SwiftUI

struct AssistantMessageView: View {
    let turn: ChatTurn
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            // Thinking section
            if let thinking = turn.streamingThinking ?? firstThinking, !thinking.isEmpty {
                ThinkingSection(text: thinking)
            }

            // Ordered text/tool blocks, interleaved as they occurred.
            ForEach(turn.blocks) { block in
                TurnBlockView(block: block, modelID: turn.assistantModelID)
                    .transition(blockTransition)
            }
        }
        .animation(.smooth(duration: 0.28), value: turn.blocks.map(\.id))
    }

    private var blockTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .opacity.combined(with: .offset(y: 6)),
                removal: .opacity
            )
    }

    private var firstThinking: String? {
        for msg in turn.assistantMessages {
            if let r = msg.message.reasoning ?? msg.message.reasoningContent, !r.isEmpty {
                return r
            }
        }
        return nil
    }
}

private struct TurnBlockView: View {
    let block: ChatTurn.Block
    var modelID: String?

    var body: some View {
        switch block {
        case .text(_, let content, let isStreaming):
            if isStreaming {
                StreamingMarkdownText(text: content, color: Palette.assistant)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                AssistantTextBubble(text: content, modelID: modelID)
            }
        case .tool(let entry):
            ToolCallView(entry: entry)
        }
    }
}

private struct AssistantTextBubble: View {
    let text: String
    var modelID: String?
    @State private var copyTrigger = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MarkdownText(source: text)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: Spacing.xs) {
                Spacer()
                if let modelID, !modelID.isEmpty {
                    Text(modelID)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityLabel("Responded with \(modelID)")
                }
                CopyButton(text: text)
            }
        }
        .foregroundStyle(Palette.assistant)
    }
}

private struct ThinkingSection: View {
    let text: String
    @State private var isExpanded: Bool = false

    var body: some View {
        CollapsibleSection(isExpanded: $isExpanded) {
            Label("Reasoning", systemImage: "brain")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        } content: {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Spacing.xs)
        }
    }
}
