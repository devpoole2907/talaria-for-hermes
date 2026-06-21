import Foundation

struct HermesMessage: Codable, Hashable, Sendable {
    let id: Int?
    let sessionId: String?
    let role: String
    let content: String?
    let toolCalls: [WireToolCall]?
    let toolCallId: String?
    let toolName: String?
    let timestamp: Double?
    let finishReason: String?
    let reasoning: String?
    let reasoningContent: String?

    init(
        id: Int?,
        sessionId: String?,
        role: String,
        content: String?,
        toolCalls: [WireToolCall]?,
        toolCallId: String?,
        toolName: String?,
        timestamp: Double?,
        finishReason: String?,
        reasoning: String?,
        reasoningContent: String?
    ) {
        self.id = id
        self.sessionId = sessionId
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.timestamp = timestamp
        self.finishReason = finishReason
        self.reasoning = reasoning
        self.reasoningContent = reasoningContent
    }

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId
        case role
        case content
        case toolCalls
        case toolCallId
        case toolName
        case timestamp
        case finishReason
        case reasoning
        case reasoningContent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeLossyIntIfPresent(forKey: .id)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        role = try container.decode(String.self, forKey: .role)
        content = try container.decodeIfPresent(String.self, forKey: .content)
        toolCalls = try? container.decodeIfPresent([WireToolCall].self, forKey: .toolCalls)
        toolCallId = try container.decodeIfPresent(String.self, forKey: .toolCallId)
        toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
        timestamp = try container.decodeIfPresent(Double.self, forKey: .timestamp)
        finishReason = try container.decodeIfPresent(String.self, forKey: .finishReason)
        reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning)
        reasoningContent = try container.decodeIfPresent(String.self, forKey: .reasoningContent)
    }
}

/// Local-identity wrapper so SwiftUI can stably identify messages even when wire id is nil.
struct TimelineMessage: Identifiable, Hashable, Sendable {
    let localID: UUID
    var message: HermesMessage
    /// Raw image data for attachments sent with this message, kept locally so the
    /// user's bubble can show thumbnails. Not persisted — lost on reload from the
    /// server, which is fine for the live session.
    var imageAttachments: [Data]
    /// Filenames of non-image documents sent with this message, shown as chips in
    /// the user's bubble. Local-only, like `imageAttachments`.
    var fileAttachmentNames: [String]

    init(
        message: HermesMessage,
        imageAttachments: [Data] = [],
        fileAttachmentNames: [String] = []
    ) {
        self.localID = UUID()
        self.message = message
        self.imageAttachments = imageAttachments
        self.fileAttachmentNames = fileAttachmentNames
    }

    var id: UUID { localID }
}

private extension KeyedDecodingContainer {
    func decodeLossyIntIfPresent(forKey key: Key) throws -> Int? {
        if let int = try? decodeIfPresent(Int.self, forKey: key) {
            return int
        }
        if let double = try? decodeIfPresent(Double.self, forKey: key) {
            return Int(double)
        }
        if let string = try? decodeIfPresent(String.self, forKey: key) {
            return Int(string)
        }
        return nil
    }
}
