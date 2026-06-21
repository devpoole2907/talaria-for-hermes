import Foundation

struct Session: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var title: String?
    let source: String?
    var model: String?
    let startedAt: Double?
    let lastActive: Double?
    let messageCount: Int?
    let toolCallCount: Int?
    let preview: String?
    let parentSessionId: String?
    let inputTokens: Int?
    let outputTokens: Int?

    var displayTitle: String {
        title?.nilIfEmpty ?? preview?.nilIfEmpty ?? "Untitled session"
    }

    var displayModelID: String {
        model?.nilIfEmpty ?? "hermes-agent"
    }

    var lastActiveDate: Date? {
        lastActive.map { Date(timeIntervalSince1970: $0) }
    }
}

struct SessionListResponse: Codable, Sendable {
    let data: [Session]
    let limit: Int?
    let offset: Int?
    let hasMore: Bool?
}

struct SessionEnvelope: Codable, Sendable {
    let session: Session
}

private extension String {
    var nilIfEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
