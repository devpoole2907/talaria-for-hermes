import SwiftUI

struct ChatModelToolbarButton: View {
    let modelID: String
    let isLoading: Bool
    var action: () -> Void

    var body: some View {
        // A custom-label button inside a `ToolbarItem` already gets the system's
        // glass capsule and tap target on iOS 26 — applying `.glassEffect` here too
        // produced a doubled-up glass look and the extra padding/maxWidth squeezed
        // the name out of the leading nav area. Let the toolbar do the styling.
        Button(action: action) {
            HStack(spacing: Spacing.xs) {
                Text(displayModelID)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }

                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("Select model")
        .accessibilityValue(displayModelID)
    }

    private var displayModelID: String {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "hermes-agent" : trimmed
    }
}
