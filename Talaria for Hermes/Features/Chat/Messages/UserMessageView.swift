import SwiftUI
import UIKit

struct UserMessageView: View {
    let turn: ChatTurn

    var body: some View {
        HStack {
            Spacer(minLength: Spacing.xl)
            VStack(alignment: .trailing, spacing: Spacing.xs) {
                if !turn.userMessage.imageAttachments.isEmpty {
                    UserImageAttachmentsView(imageData: turn.userMessage.imageAttachments)
                }
                if !turn.userMessage.fileAttachmentNames.isEmpty {
                    UserFileAttachmentsView(filenames: turn.userMessage.fileAttachmentNames)
                }
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

private struct UserFileAttachmentsView: View {
    let filenames: [String]

    var body: some View {
        VStack(alignment: .trailing, spacing: Spacing.xs) {
            ForEach(Array(filenames.enumerated()), id: \.offset) { _, name in
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "doc")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(name)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, Spacing.s)
                .padding(.vertical, Spacing.xs)
                .frame(maxWidth: 240, alignment: .leading)
                .background(Palette.user.opacity(0.18))
                .clipShape(.rect(cornerRadius: Radii.large))
            }
        }
    }
}

private struct UserImageAttachmentsView: View {
    let imageData: [Data]

    private let maxThumbnail: CGFloat = 180

    var body: some View {
        let images = imageData.compactMap(UIImage.init(data:))
        if !images.isEmpty {
            HStack(alignment: .top, spacing: Spacing.xs) {
                ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: maxThumbnail, maxHeight: maxThumbnail)
                        .clipShape(.rect(cornerRadius: Radii.large))
                }
            }
        }
    }
}
