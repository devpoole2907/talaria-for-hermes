import SwiftUI

struct ChatComposer: View {
    @Binding var text: String
    let isWorking: Bool
    var onSend: (String) -> Void
    var onStop: () -> Void
    var onAdd: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if shouldShowSlashMenu {
                SlashCommandSuggestionMenu(
                    suggestions: slashSuggestions,
                    onSelect: applySlashSuggestion
                )
            }

            HStack(alignment: .bottom, spacing: Spacing.s) {
                addButton
                messageField
            }
        }
        .padding(.horizontal, Spacing.m)
        .padding(.top, Spacing.s)
        .padding(.bottom, Spacing.s)
        .frame(maxWidth: .infinity)
        .background(.clear)
    }

    private var messageField: some View {
        HStack(alignment: .bottom, spacing: Spacing.xs) {
            TextField("Message", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...5)
                .submitLabel(.send)
                .onSubmit(send)
                .padding(.leading, Spacing.l)
                .padding(.vertical, Spacing.s)
                .frame(minHeight: TapTarget.minimum)

            sendOrStopButton
                .padding(.trailing, Spacing.xs)
        }
            .frame(minHeight: TapTarget.minimum)
            .glassEffect(in: .rect(cornerRadius: 24, style: .continuous))
    }

    private var addButton: some View {
        Button(action: onAdd) {
            Image(systemName: "plus")
                .font(.body.bold())
                .frame(width: TapTarget.minimum, height: TapTarget.minimum)
                .foregroundStyle(.secondary)
                .glassEffect(in: .circle)
        }
        .accessibilityLabel("Add attachment")
    }

    private var sendOrStopButton: some View {
        Group {
            if isWorking {
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.body.bold())
                        .frame(width: 34, height: 34)
                        .foregroundStyle(.white)
                        .background(.red, in: .circle)
                }
                .accessibilityLabel("Stop generating")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.body.bold())
                        .frame(width: 34, height: 34)
                        .foregroundStyle(.white)
                        .background(canSend ? Color.accentColor : Color.secondary.opacity(0.3), in: .circle)
                }
                .disabled(!canSend)
                .accessibilityLabel("Send message")
            }
        }
        .frame(width: TapTarget.minimum, height: TapTarget.minimum)
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isWorking
    }

    private var slashQuery: String? {
        guard text.hasPrefix("/") else { return nil }
        let raw = String(text.dropFirst())
        guard !raw.contains(where: \.isWhitespace) else { return nil }
        return raw
    }

    private var slashSuggestions: [SlashCommandSuggestion] {
        guard let slashQuery else { return [] }
        return SlashCommandSuggestion.defaults.filter { $0.matches(slashQuery) }
    }

    private var shouldShowSlashMenu: Bool {
        !isWorking && slashQuery != nil && !slashSuggestions.isEmpty
    }

    private func send() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSend(trimmed)
        text = ""
    }

    private func applySlashSuggestion(_ suggestion: SlashCommandSuggestion) {
        text = suggestion.prefill
    }
}
