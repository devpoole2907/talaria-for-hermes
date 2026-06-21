import SwiftUI

/// A pending attachment the user has picked but not yet sent.
struct ComposerAttachment: Identifiable, Equatable {
    enum Kind { case photo, file }

    let id = UUID()
    let name: String
    let kind: Kind
    var data: Data?

    var systemImage: String {
        switch kind {
        case .photo: return "photo"
        case .file: return "doc"
        }
    }
}

struct ChatComposer: View {
    @Binding var text: String
    @Binding var attachments: [ComposerAttachment]
    let isWorking: Bool
    var onSend: (String) -> Void
    var onStop: () -> Void
    var onAttachPhoto: () -> Void = {}
    var onAttachFile: () -> Void = {}

    @FocusState private var isMessageFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if shouldShowSlashMenu {
                SlashCommandSuggestionMenu(
                    suggestions: slashSuggestions,
                    onSelect: applySlashSuggestion
                )
            }

            if !attachments.isEmpty {
                attachmentChips
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

    private var attachmentChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.xs) {
                ForEach(attachments) { attachment in
                    AttachmentChip(attachment: attachment) {
                        attachments.removeAll { $0.id == attachment.id }
                    }
                }
            }
            .padding(.horizontal, Spacing.xs)
        }
    }

    private var messageField: some View {
        HStack(alignment: .bottom, spacing: Spacing.xs) {
            TextField("Message", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...5)
                .submitLabel(.send)
                .focused($isMessageFieldFocused)
                .onSubmit(send)
                .onChange(of: text) { oldValue, newValue in
                    #if targetEnvironment(macCatalyst)
                    handleMacMultilineSubmit(oldValue: oldValue, newValue: newValue)
                    #endif
                }
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
        Menu {
            Button(action: onAttachPhoto) {
                Label("Photo Library", systemImage: "photo")
            }
            Button(action: onAttachFile) {
                Label("Files", systemImage: "folder")
            }
        } label: {
            Image(systemName: "plus")
                .font(.body.bold())
                .frame(width: TapTarget.minimum, height: TapTarget.minimum)
                .foregroundStyle(.secondary)
                .glassEffect(in: .circle)
        }
        .tint(.secondary)
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
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (hasText || !attachments.isEmpty) && !isWorking
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
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        isMessageFieldFocused = false
        onSend(trimmed)
        text = ""
        Task { @MainActor in
            await Task.yield()
            text = ""
            try? await Task.sleep(for: .milliseconds(150))
            text = ""
        }
    }

    #if targetEnvironment(macCatalyst)
    private func handleMacMultilineSubmit(oldValue: String, newValue: String) {
        guard isMessageFieldFocused else { return }
        guard let newlineRange = insertedNewlineRange(oldValue: oldValue, newValue: newValue) else { return }

        var submittedText = newValue
        submittedText.removeSubrange(newlineRange)
        text = submittedText
        send()
    }

    private func insertedNewlineRange(oldValue: String, newValue: String) -> Range<String.Index>? {
        guard newValue.count == oldValue.count + 1 else { return nil }

        var oldIndex = oldValue.startIndex
        var newIndex = newValue.startIndex

        while oldIndex < oldValue.endIndex,
              newIndex < newValue.endIndex,
              oldValue[oldIndex] == newValue[newIndex] {
            oldValue.formIndex(after: &oldIndex)
            newValue.formIndex(after: &newIndex)
        }

        guard newIndex < newValue.endIndex, newValue[newIndex] == "\n" else { return nil }

        let afterNewline = newValue.index(after: newIndex)
        guard oldValue[oldIndex...] == newValue[afterNewline...] else { return nil }
        return newIndex..<afterNewline
    }
    #endif

    private func applySlashSuggestion(_ suggestion: SlashCommandSuggestion) {
        text = suggestion.prefill
    }
}

private struct AttachmentChip: View {
    let attachment: ComposerAttachment
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: attachment.systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(attachment.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Remove \(attachment.name)")
        }
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xs)
        .frame(maxWidth: 200)
        .glassEffect(in: .capsule)
    }
}
