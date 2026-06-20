import SwiftUI

struct ChatModelToolbarButton: View {
    let modelID: String
    let isLoading: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "cpu")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(modelID)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Spacing.l)
            .frame(minHeight: TapTarget.minimum)
            .frame(maxWidth: 220)
            .contentShape(.rect)
            .glassEffect(in: .rect(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Select model")
        .accessibilityValue(modelID)
    }
}
