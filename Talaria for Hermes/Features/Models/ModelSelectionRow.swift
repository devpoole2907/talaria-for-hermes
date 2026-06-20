import SwiftUI

struct ModelSelectionRow: View {
    let title: String
    let subtitle: String?
    let selected: Bool
    var isLoading: Bool = false

    var body: some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: "cpu")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else if selected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
            }
        }
        .frame(minHeight: TapTarget.minimum)
        .contentShape(.rect)
    }
}
