import SwiftUI

struct ThinkingIndicatorView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Spacing.s) {
            if reduceMotion {
                Image(systemName: "sparkles")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            } else {
                ShimmerView()
                    .frame(width: 60)
            }
            Text("Thinking…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Assistant is thinking")
    }
}
