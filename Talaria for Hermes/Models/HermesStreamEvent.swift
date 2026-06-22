import Foundation

/// Rich payload for an approval.request event on the Runs API path.
/// The run is paused (status: waiting_for_approval) until a choice is posted.
struct ApprovalRequest: Sendable, Codable {
    let runID: String
    let command: String
    let description: String
    let choices: [String]       // ["once", "session", "always", "deny"]
    let allowPermanent: Bool    // whether "always" is shown
    let patternKey: String?
}

enum HermesStreamEvent: Sendable {
    case runStarted(runID: String)
    case messageStarted(messageID: String)
    case assistantDelta(messageID: String, text: String)
    case assistantCompleted(messageID: String, content: String, reasoning: String?)
    case thinkingDelta(messageID: String, text: String)
    case toolStarted(messageID: String, name: String, arguments: String?)
    case toolCompleted(messageID: String, name: String?)
    case toolProgress(messageID: String, name: String, text: String)
    /// Session-stream path: legacy approval with separate approvalID.
    case approvalRequired(runID: String, approvalID: String, prompt: String)
    /// Runs API path: richer approval with command, description, choices.
    case runsApprovalRequired(ApprovalRequest)
    case runCompleted(messages: [HermesMessage], usage: TokenUsage?)
    case runFailed(error: String)
    case unknown(event: String)
}
