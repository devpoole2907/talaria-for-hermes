import Foundation

struct SlashCommandSuggestion: Identifiable, Hashable, Sendable {
    let command: String
    let title: String
    let subtitle: String
    let systemImage: String
    let prefill: String

    var id: String { command }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let lowered = query.lowercased()
        return command.dropFirst().lowercased().contains(lowered)
            || title.lowercased().contains(lowered)
            || subtitle.lowercased().contains(lowered)
    }

    static let defaults: [SlashCommandSuggestion] = [
        SlashCommandSuggestion(
            command: "/model",
            title: "Model",
            subtitle: "Switch provider or model",
            systemImage: "cpu",
            prefill: "/model "
        ),
        SlashCommandSuggestion(
            command: "/status",
            title: "Status",
            subtitle: "Session and runtime state",
            systemImage: "chart.bar.doc.horizontal",
            prefill: "/status"
        ),
        SlashCommandSuggestion(
            command: "/tools",
            title: "Tools",
            subtitle: "Toolset controls",
            systemImage: "wrench.and.screwdriver",
            prefill: "/tools "
        ),
        SlashCommandSuggestion(
            command: "/skills",
            title: "Skills",
            subtitle: "Skill browser",
            systemImage: "sparkles",
            prefill: "/skills "
        ),
        SlashCommandSuggestion(
            command: "/memory",
            title: "Memory",
            subtitle: "Memory settings",
            systemImage: "brain.head.profile",
            prefill: "/memory "
        ),
        SlashCommandSuggestion(
            command: "/new",
            title: "New",
            subtitle: "Fresh session",
            systemImage: "plus.message",
            prefill: "/new"
        ),
        SlashCommandSuggestion(
            command: "/title",
            title: "Title",
            subtitle: "Rename session",
            systemImage: "textformat",
            prefill: "/title "
        ),
        SlashCommandSuggestion(
            command: "/help",
            title: "Help",
            subtitle: "Command reference",
            systemImage: "questionmark.circle",
            prefill: "/help"
        ),
    ]
}
