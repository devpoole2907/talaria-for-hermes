import SwiftUI

/// Shown on the active turn while its dropped live stream is being recovered by
/// polling the server. Distinct from `ThinkingIndicatorView` so the user can tell
/// "the connection blipped, hang on" apart from "the assistant is still working".
struct ReconnectingIndicatorView: View {
    var body: some View {
        HStack(spacing: Spacing.s) {
            ProgressView()
                .controlSize(.small)
            Text("Reconnecting…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Reconnecting to the assistant")
    }
}
