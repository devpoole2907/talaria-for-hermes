import Foundation
import SwiftData

// MARK: - StoredSession
//
// CloudKit private DB constraints: every stored property must have a default
// value or be optional; no @Attribute(.unique); relationships must be optional.

@Model final class StoredSession {
    /// Server session id — the join key against the Hermes API.
    var id: String = ""
    /// ServerProfile.id.uuidString — keeps each profile's data isolated.
    var profileID: String = ""
    var title: String?
    var model: String?
    var source: String?
    var lastActive: Double = 0
    /// Local write timestamp; used to resolve CloudKit merge conflicts (last-write-wins).
    var updatedAt: Double = 0

    @Relationship(deleteRule: .cascade, inverse: \StoredMessage.session)
    var messages: [StoredMessage]? = []

    init(
        id: String,
        profileID: String,
        title: String? = nil,
        model: String? = nil,
        source: String? = nil,
        lastActive: Double = 0,
        updatedAt: Double = Date.now.timeIntervalSince1970
    ) {
        self.id = id
        self.profileID = profileID
        self.title = title
        self.model = model
        self.source = source
        self.lastActive = lastActive
        self.updatedAt = updatedAt
    }
}

// MARK: - StoredMessage

@Model final class StoredMessage {
    /// Stable local UUID string — survives re-downloads and CloudKit round-trips.
    var localID: String = ""
    /// Server message id when the message has been acknowledged server-side.
    var serverID: Int? = nil
    var sessionID: String = ""
    var profileID: String = ""
    var role: String = ""             // "user" / "assistant" / "tool"
    var content: String? = nil
    var reasoning: String? = nil
    var reasoningContent: String? = nil
    /// JSON-encoded [WireToolCall], stored as a string for CloudKit compatibility.
    var toolCallsJSON: String? = nil
    var toolCallID: String? = nil
    var toolName: String? = nil
    var timestamp: Double = 0
    /// nil means the assistant reply is incomplete / still streaming (partial persisted on drop).
    var finishReason: String? = nil
    /// Derived from finishReason != nil; redundant but makes fetches cheaper.
    var isComplete: Bool = false
    /// Position within the session; preserves server ordering through CloudKit sync.
    var orderIndex: Int = 0
    var updatedAt: Double = 0

    // CloudKit: relationships must be optional.
    var session: StoredSession? = nil

    init(
        localID: String,
        serverID: Int? = nil,
        sessionID: String,
        profileID: String,
        role: String,
        content: String? = nil,
        reasoning: String? = nil,
        reasoningContent: String? = nil,
        toolCallsJSON: String? = nil,
        toolCallID: String? = nil,
        toolName: String? = nil,
        timestamp: Double = 0,
        finishReason: String? = nil,
        orderIndex: Int = 0,
        updatedAt: Double = Date.now.timeIntervalSince1970,
        session: StoredSession? = nil
    ) {
        self.localID = localID
        self.serverID = serverID
        self.sessionID = sessionID
        self.profileID = profileID
        self.role = role
        self.content = content
        self.reasoning = reasoning
        self.reasoningContent = reasoningContent
        self.toolCallsJSON = toolCallsJSON
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.timestamp = timestamp
        self.finishReason = finishReason
        self.isComplete = finishReason != nil
        self.orderIndex = orderIndex
        self.updatedAt = updatedAt
        self.session = session
    }
}
