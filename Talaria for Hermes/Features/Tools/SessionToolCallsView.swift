import SwiftUI

struct SessionToolCallsView: View {
    let session: Session
    private static let maxContentWidth: CGFloat = 560

    @Environment(AppModel.self) private var appModel
    @State private var store: ChatStore?

    var body: some View {
        Group {
            if let store {
                toolContent(for: store)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: Self.maxContentWidth, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
        .navigationTitle("Tools")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: session.id) { await loadStore() }
    }

    @ViewBuilder
    private func toolContent(for store: ChatStore) -> some View {
        let items = toolCalls(in: store)

        if store.loading && items.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if items.isEmpty {
            ContentUnavailableView(
                "No Tools",
                systemImage: "wrench.and.screwdriver",
                description: Text("Tool calls for this session will appear here.")
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.m) {
                    toolCountHeader(count: items.count)

                    ForEach(items) { item in
                        SessionToolCallRow(item: item)
                    }
                }
                .padding(Spacing.l)
            }
            .contentMargins(.bottom, Spacing.l, for: .scrollContent)
        }
    }

    private func toolCountHeader(count: Int) -> some View {
        HStack(spacing: Spacing.s) {
            Text("TOOLS")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text(count.formatted())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .combine)
    }

    private func toolCalls(in store: ChatStore) -> [SessionToolCallItem] {
        store.turns.enumerated().flatMap { offset, turn in
            turn.blocks.compactMap { block in
                guard case .tool(let entry) = block else { return nil }
                return SessionToolCallItem(
                    id: "\(turn.id.uuidString)-\(entry.id)",
                    turnNumber: offset + 1,
                    prompt: turn.userMessage.message.content ?? "",
                    entry: entry
                )
            }
        }
    }

    @Sendable
    private func loadStore() async {
        let chatStore = appModel.openChat(for: session)
        store = chatStore
        if chatStore.timeline.isEmpty && !chatStore.loading {
            await chatStore.load()
        }
        chatStore.recoverIfNeeded()
    }
}

private struct SessionToolCallItem: Identifiable {
    let id: String
    let turnNumber: Int
    let prompt: String
    let entry: ChatTurn.ToolEntry

    var hasDetail: Bool {
        entry.arguments?.isEmpty == false
        || entry.output?.isEmpty == false
        || entry.progress?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var promptPreview: String? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct SessionToolCallRow: View {
    let item: SessionToolCallItem

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Button(action: toggle) {
                rowHeader
            }
            .buttonStyle(.plain)
            .disabled(!item.hasDetail)

            if isExpanded {
                rowDetail
            }
        }
        .padding(.vertical, Spacing.s)
        .padding(.horizontal, Spacing.m)
        .background(.regularMaterial, in: .rect(cornerRadius: Radii.medium))
        .overlay {
            RoundedRectangle(cornerRadius: Radii.medium)
                .strokeBorder(.secondary.opacity(0.16), lineWidth: 1)
        }
        .overlay(alignment: .leading) {
            Capsule()
                .fill(item.entry.isRunning ? Palette.toolRunning : Palette.toolComplete)
                .frame(width: 3)
                .padding(.vertical, Spacing.s)
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: isExpanded)
    }

    private var rowHeader: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            Image(systemName: ToolEmojiMap.symbol(for: item.entry.name))
                .font(.caption)
                .foregroundStyle(item.entry.isRunning ? Palette.toolRunning : Palette.toolComplete)
                .frame(width: 24, height: 24)
                .background((item.entry.isRunning ? Palette.toolRunning : Palette.toolComplete).opacity(0.14), in: .circle)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.xs) {
                    Text(ToolCallFormatting.displayName(item.entry.name))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: Spacing.s)

                    ToolStatusBadge(isRunning: item.entry.isRunning)
                }

                Text(ToolCallFormatting.summary(for: item.entry))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)

                Text("Turn \(item.turnNumber)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
            }

            if item.hasDetail {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .padding(.top, Spacing.xs)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: TapTarget.minimum)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint(item.hasDetail ? (isExpanded ? "Tap to collapse" : "Tap to expand") : "")
    }

    private var rowDetail: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if let prompt = item.promptPreview {
                ToolPayloadSection(title: "Prompt", systemImage: "quote.bubble") {
                    Text(prompt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if let args = item.entry.arguments, !args.isEmpty {
                ToolPayloadSection(title: "Context", systemImage: "curlybraces") {
                    ToolPayloadBody(raw: args)
                }
            }

            if let output = item.entry.output {
                ToolPayloadSection(title: "Output", systemImage: "arrow.down.doc") {
                    ToolPayloadBody(raw: ToolCallFormatting.cleanOutput(output))
                }
            } else if let progress = item.entry.progress?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !progress.isEmpty {
                ToolPayloadSection(title: "Progress", systemImage: "waveform.path.ecg") {
                    ToolValueBlock(text: progress)
                }
            }
        }
    }

    private func toggle() {
        guard item.hasDetail else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            isExpanded.toggle()
        }
    }
}
