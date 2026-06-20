import Foundation

struct TokenUsage: Codable, Hashable, Sendable {
    let inputTokens: Int?
    let outputTokens: Int?
    let totalTokens: Int?
    let promptTokens: Int?
    let completionTokens: Int?

    var input: Int? { inputTokens ?? promptTokens }
    var output: Int? { outputTokens ?? completionTokens }
}
