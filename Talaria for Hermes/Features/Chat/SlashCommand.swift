import Foundation

/// A recognized slash command typed in the composer. The Hermes REST API does
/// not execute slash commands (it feeds them to the LLM, which improvises), so
/// the app intercepts these and runs them itself — opening UI for action
/// commands or printing an inline result for info commands. Unrecognized
/// `/...` text falls through to the agent as a normal message.
enum SlashCommand: Equatable {
    case model(argument: String?)
    case newSession
    case title(String?)
    case tools
    case status
    case skills
    case memory
    case help

    /// Parses a submitted message. Returns nil when the text isn't a recognized
    /// command (including non-slash text), so the caller sends it to the agent.
    static func parse(_ text: String) -> SlashCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let body = trimmed.dropFirst()
        let split = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let name = split.first?.lowercased() else { return nil }
        let argument = split.count > 1
            ? String(split[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let arg = (argument?.isEmpty == false) ? argument : nil

        switch name {
        case "model": return .model(argument: arg)
        case "new": return .newSession
        case "title", "rename": return .title(arg)
        case "tools": return .tools
        case "status": return .status
        case "skills": return .skills
        case "memory": return .memory
        case "help": return .help
        default: return nil
        }
    }

    /// Info commands print an inline result; action commands drive UI instead.
    var isInfo: Bool {
        switch self {
        case .status, .skills, .memory, .help: return true
        case .model, .newSession, .title, .tools: return false
        }
    }
}
