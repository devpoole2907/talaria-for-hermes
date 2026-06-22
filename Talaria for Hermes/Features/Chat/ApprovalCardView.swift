import SwiftUI

/// Actionable approval card shown when a Runs API run pauses for user consent.
/// The run is server-paused (status: waiting_for_approval) until the user
/// picks a choice. Dismissing this card without choosing leaves the run paused
/// (the user can tap Stop to abort). After a choice is posted the run resumes
/// and the card disappears automatically (pendingApproval is cleared).
struct ApprovalCardView: View {
    let approval: ApprovalRequest
    let onChoose: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            // Header
            HStack(spacing: Spacing.s) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
                Text("Approval Required")
                    .font(.headline)
                Spacer()
            }

            // Command (monospace)
            if !approval.command.isEmpty {
                Text(approval.command)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.primary)
                    .padding(Spacing.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: Radii.small))
            }

            // Risk description
            if !approval.description.isEmpty, approval.description != approval.command {
                Text(approval.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Choice buttons
            VStack(spacing: Spacing.s) {
                ForEach(displayChoices, id: \.key) { choice in
                    Button(action: { onChoose(choice.key) }) {
                        Text(choice.label)
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Spacing.s)
                    }
                    .buttonStyle(.bordered)
                    .tint(choice.tint)
                }
            }
        }
        .padding(Spacing.l)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radii.large))
        .overlay(
            RoundedRectangle(cornerRadius: Radii.large)
                .strokeBorder(.orange.opacity(0.35), lineWidth: 1)
        )
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
    }

    // MARK: - Choice display

    private struct DisplayChoice {
        let key: String
        let label: String
        let tint: Color
    }

    private var displayChoices: [DisplayChoice] {
        var result: [DisplayChoice] = []
        for key in approval.choices {
            switch key {
            case "once":
                result.append(DisplayChoice(key: key, label: "Approve Once", tint: .blue))
            case "session":
                result.append(DisplayChoice(key: key, label: "Approve for Session", tint: .blue))
            case "always":
                // Only show "always" if the server explicitly allows it.
                if approval.allowPermanent {
                    result.append(DisplayChoice(key: key, label: "Always Allow", tint: .orange))
                }
            case "deny":
                result.append(DisplayChoice(key: key, label: "Deny", tint: .red))
            default:
                result.append(DisplayChoice(key: key, label: key.capitalized, tint: .primary))
            }
        }
        return result
    }
}
