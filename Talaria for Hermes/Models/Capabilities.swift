import Foundation

struct Capabilities: Codable, Sendable {
    let object: String?
    let platform: String?
    let model: String?
    let auth: Auth?
    let features: Features?

    struct Auth: Codable, Sendable {
        let authType: String?
        let required: Bool?

        enum CodingKeys: String, CodingKey {
            case authType = "type"
            case required
        }
    }

    struct Features: Codable, Sendable {
        let chatCompletions: Bool?
        let chatCompletionsStreaming: Bool?
        let sessionChat: Bool?
        let sessionChatStreaming: Bool?
        let runSubmission: Bool?
        let runStop: Bool?
        let runApprovalResponse: Bool?
        let approvalEvents: Bool?
        let toolProgressEvents: Bool?
    }
}
