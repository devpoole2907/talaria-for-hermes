import SwiftUI

struct ServerProfileRow: View {
    let profile: ServerProfile
    let isActive: Bool
    var onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: Spacing.m) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(profile.name).bold()
                    Text(profile.url.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: Spacing.s)
                if isActive {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Active profile")
                }
            }
            .frame(minHeight: TapTarget.minimum)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
