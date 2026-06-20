import SwiftUI

struct ModelProviderRow: View {
    let group: ModelProviderGroup
    let selectedModelID: String

    var body: some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: group.provider == nil ? "server.rack" : "building.2.crop.circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(group.name)
                    .font(.body)
                Text(group.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(group.modelCountText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .frame(minHeight: TapTarget.minimum)
        .accessibilityElement(children: .combine)
        .accessibilityValue(group.modelCountAccessibilityText)
    }

    private var isSelected: Bool {
        group.models.contains { $0.id == selectedModelID }
    }
}
