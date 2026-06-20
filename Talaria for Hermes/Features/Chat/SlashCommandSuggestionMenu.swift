import SwiftUI

struct SlashCommandSuggestionMenu: View {
    let suggestions: [SlashCommandSuggestion]
    var onSelect: (SlashCommandSuggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(suggestions) { suggestion in
                Button {
                    onSelect(suggestion)
                } label: {
                    HStack(spacing: Spacing.m) {
                        Image(systemName: suggestion.systemImage)
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(suggestion.command)
                                .font(.callout)
                                .foregroundStyle(.primary)
                            Text(suggestion.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .frame(minHeight: TapTarget.minimum)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)

                if suggestion.id != suggestions.last?.id {
                    Divider()
                        .padding(.leading, 24 + Spacing.m)
                }
            }
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.xs)
        .background(.regularMaterial, in: .rect(cornerRadius: Radii.medium))
        .padding(.horizontal, Spacing.m)
        .shadow(color: .black.opacity(0.08), radius: 16, y: 8)
    }
}
