import SwiftUI

struct SessionRowView: View {
    let session: Session

    var body: some View {
        HStack(spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(session.displayTitle)
                    .bold()
                    .lineLimit(1)
                if let date = session.lastActiveDate {
                    Text(date, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let count = session.messageCount, count > 0 {
                    Text("^[\(count) message](inflect: true)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: Spacing.s)
            if let source = session.source, source != "api_server" {
                Text(source)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, Spacing.s)
                    .padding(.vertical, 3)
                    .background(.secondary.opacity(0.15))
                    .clipShape(.capsule)
            }
        }
        .frame(minHeight: TapTarget.minimum)
        .accessibilityElement(children: .combine)
    }
}
