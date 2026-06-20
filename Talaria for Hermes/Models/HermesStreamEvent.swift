import Foundation

enum HermesStreamEvent: Sendable {
    case runStarted(runID: String)
    case messageStarted(messageID: String)
    case assistantDelta(messageID: String, text: String)
    case assistantCompleted(messageID: String, content: String, reasoning: String?)
    case thinkingDelta(messageID: String, text: String)
    case toolStarted(messageID: String, name: String, arguments: String?)
    case toolCompleted(messageID: String, name: String?)
    case toolProgress(messageID: String, name: String, text: String)
    case approvalRequired(runID: String, approvalID: String, prompt: String)
    case runCompleted(messages: [HermesMessage], usage: TokenUsage?)
    case runFailed(error: String)
    case unknown(event: String)
}
