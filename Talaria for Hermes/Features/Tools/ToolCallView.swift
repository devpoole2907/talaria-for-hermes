import SwiftUI

struct ToolCallView: View {
    let entry: ChatTurn.ToolEntry

    @State private var isExpanded: Bool = false

    var body: some View {
        ToolCallFrame(isRunning: entry.isRunning) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                Button(action: toggle) {
                    ToolCallHeader(
                        name: entry.name,
                        isRunning: entry.isRunning,
                        isExpanded: isExpanded,
                        canExpand: hasDetail
                    )
                }
                .buttonStyle(.plain)
                .disabled(!hasDetail)

                if isExpanded {
                    detail
                }
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: isExpanded)
    }

    @ViewBuilder
    private var detail: some View {
        if let args = entry.arguments, !args.isEmpty {
            ToolPayloadSection(title: "Input", systemImage: "curlybraces") {
                ToolPayloadBody(raw: args)
            }
        }
        if let output = entry.output {
            ToolPayloadSection(title: "Output", systemImage: "arrow.down.doc") {
                ToolPayloadBody(raw: ToolCallFormatting.cleanOutput(output))
            }
        } else if let progress = entry.progress?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !progress.isEmpty {
            ToolPayloadSection(title: "Progress", systemImage: "waveform.path.ecg") {
                ToolValueBlock(text: progress)
            }
        }
    }

    private var hasDetail: Bool {
        entry.arguments?.isEmpty == false
        || entry.output?.isEmpty == false
        || entry.progress?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private func toggle() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            isExpanded.toggle()
        }
    }
}

private struct ToolCallFrame<Content: View>: View {
    let isRunning: Bool
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.vertical, Spacing.s)
            .padding(.horizontal, Spacing.m)
            .background(.regularMaterial, in: .rect(cornerRadius: Radii.medium))
            .overlay {
                RoundedRectangle(cornerRadius: Radii.medium)
                    .strokeBorder(.secondary.opacity(0.16), lineWidth: 1)
            }
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(statusColor)
                    .frame(width: 3)
                    .padding(.vertical, Spacing.s)
            }
    }

    private var statusColor: Color {
        isRunning ? Palette.toolRunning : Palette.toolComplete
    }
}

private struct ToolCallHeader: View {
    let name: String
    let isRunning: Bool
    let isExpanded: Bool
    let canExpand: Bool

    var body: some View {
        HStack(spacing: Spacing.s) {
            ToolIconBadge(name: name, isRunning: isRunning)

            Text(ToolCallFormatting.displayName(name))
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.primary)

            Spacer(minLength: Spacing.s)

            ToolStatusPill(isRunning: isRunning)

            if canExpand {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: TapTarget.minimum)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint(canExpand ? (isExpanded ? "Tap to collapse" : "Tap to expand") : "")
    }
}

private struct ToolIconBadge: View {
    let name: String
    let isRunning: Bool

    var body: some View {
        Image(systemName: ToolEmojiMap.symbol(for: name))
            .font(.caption)
            .foregroundStyle(statusColor)
            .frame(width: 24, height: 24)
            .background(statusColor.opacity(0.14), in: .circle)
            .overlay {
                Circle()
                    .strokeBorder(statusColor.opacity(0.24), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }

    private var statusColor: Color {
        isRunning ? Palette.toolRunning : Palette.toolComplete
    }
}

private struct ToolStatusPill: View {
    let isRunning: Bool

    var body: some View {
        HStack(spacing: Spacing.xs) {
            if isRunning {
                ProgressView()
                    .controlSize(.mini)
                    .tint(Palette.toolRunning)
                Text("Running")
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .imageScale(.small)
                Text("Done")
            }
        }
        .font(.caption)
        .bold()
        .foregroundStyle(statusColor)
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xs)
        .background(statusColor.opacity(0.12), in: .capsule)
        .accessibilityLabel(isRunning ? "Tool running" : "Tool complete")
    }

    private var statusColor: Color {
        isRunning ? Palette.toolRunning : Palette.toolComplete
    }
}
