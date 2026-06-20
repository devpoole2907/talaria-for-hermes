import SwiftUI

struct ToolStatusIndicator: View {
    let status: LiveTool.Status

    var body: some View {
        HStack(spacing: Spacing.xs) {
            switch status {
            case .running:
                ProgressView()
                    .controlSize(.small)
                Text("Running")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Palette.toolRunning)
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Palette.toolComplete)
                Text("Done")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Palette.toolComplete)
            }
        }
    }
}

struct ToolStatusBadge: View {
    let isRunning: Bool

    var body: some View {
        if isRunning {
            ProgressView().controlSize(.mini)
        } else {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Palette.toolComplete)
                .imageScale(.small)
        }
    }
}
