import Foundation
import SwiftData

// MARK: - PersistenceController

/// Builds and owns the SwiftData ModelContainer.
/// CloudKit sync is enabled automatically when the app's entitlements carry the
/// iCloud container identifier; falls back to local-only in sim / CI builds where
/// the container isn't provisioned. The `ModelConfiguration.cloudKitDatabase: .automatic`
/// flag handles that distinction at runtime — no code change required.
final class PersistenceController {
    static let shared = PersistenceController()

    let container: ModelContainer

    private init() {
        let schema = Schema([StoredSession.self, StoredMessage.self])
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .automatic
        )
        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Non-recoverable: if the store is corrupt, wipe and start fresh rather
            // than crash-loop. Data will resync from server on next launch.
            let url = config.url
            try? FileManager.default.removeItem(at: url)
            container = try! ModelContainer(for: schema, configurations: [
                ModelConfiguration(schema: schema, isStoredInMemoryOnly: false, cloudKitDatabase: .automatic)
            ])
        }
    }
}

// MARK: - ChatRepository

/// Main-actor repository bridging SwiftData ↔ the app's wire models.
/// All methods run on the main context, keeping SwiftData and @Observable
/// state mutations on the same actor with no concurrency overhead.
@MainActor
final class ChatRepository {
    private let context: ModelContext

    private static let toolCallEncoder = JSONEncoder()
    private static let toolCallDecoder = JSONDecoder()

    init(container: ModelContainer) {
        self.context = container.mainContext
    }

    // MARK: - Messages

    /// Returns locally persisted messages for a session, ordered by `orderIndex`.
    /// Called synchronously before the network fetch so the UI populates instantly.
    func messages(sessionID: String, profileID: String) -> [TimelineMessage] {
        let predicate = #Predicate<StoredMessage> {
            $0.sessionID == sessionID && $0.profileID == profileID
        }
        let descriptor = FetchDescriptor<StoredMessage>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.orderIndex)]
        )
        guard let stored = try? context.fetch(descriptor) else { return [] }
        return stored.compactMap { toTimelineMessage($0) }
    }

    /// Replaces the full stored message set for a session with the given ordered timeline.
    /// Use after a merge or on finalize so local storage matches the reconciled truth.
    func upsertMessages(_ timeline: [TimelineMessage], sessionID: String, profileID: String) {
        // Fetch existing stored messages keyed by localID for O(1) lookups.
        let predicate = #Predicate<StoredMessage> {
            $0.sessionID == sessionID && $0.profileID == profileID
        }
        let descriptor = FetchDescriptor<StoredMessage>(predicate: predicate)
        let existing = (try? context.fetch(descriptor)) ?? []
        var byLocalID = Dictionary(uniqueKeysWithValues: existing.map { ($0.localID, $0) })

        var localIDsSeen = Set<String>()
        for (index, tlMessage) in timeline.enumerated() {
            let key = tlMessage.localID.uuidString
            localIDsSeen.insert(key)
            if let stored = byLocalID[key] {
                // Update in place — avoids deleting and re-inserting.
                apply(tlMessage, orderIndex: index, to: stored)
            } else {
                let stored = toStoredMessage(tlMessage, sessionID: sessionID, profileID: profileID, orderIndex: index)
                context.insert(stored)
                byLocalID[key] = stored
            }
        }

        // Remove messages no longer in the timeline (server deleted or merged away).
        for stored in existing where !localIDsSeen.contains(stored.localID) {
            context.delete(stored)
        }

        try? context.save()
    }

    /// Cheap single-message write for an in-flight partial during streaming.
    /// Does NOT delete other messages — only upserts the one partial.
    func upsertPartial(_ message: TimelineMessage, sessionID: String, profileID: String, orderIndex: Int) {
        let key = message.localID.uuidString
        let predicate = #Predicate<StoredMessage> { $0.localID == key }
        let descriptor = FetchDescriptor<StoredMessage>(predicate: predicate)
        if let existing = try? context.fetch(descriptor), let stored = existing.first {
            apply(message, orderIndex: orderIndex, to: stored)
        } else {
            let stored = toStoredMessage(message, sessionID: sessionID, profileID: profileID, orderIndex: orderIndex)
            context.insert(stored)
        }
        try? context.save()
    }

    // MARK: - Sessions

    /// Returns locally persisted sessions for a profile.
    func sessions(profileID: String) -> [Session] {
        let predicate = #Predicate<StoredSession> { $0.profileID == profileID }
        let descriptor = FetchDescriptor<StoredSession>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.lastActive, order: .reverse)]
        )
        guard let stored = try? context.fetch(descriptor) else { return [] }
        return stored.map { toSession($0) }
    }

    /// Upserts the given server sessions into the local store.
    func upsertSessions(_ sessions: [Session], profileID: String) {
        let predicate = #Predicate<StoredSession> { $0.profileID == profileID }
        let descriptor = FetchDescriptor<StoredSession>(predicate: predicate)
        let existing = (try? context.fetch(descriptor)) ?? []
        var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

        let now = Date.now.timeIntervalSince1970
        for session in sessions {
            if let stored = byID[session.id] {
                stored.title = session.title
                stored.model = session.model
                stored.source = session.source
                stored.lastActive = session.lastActive ?? stored.lastActive
                stored.updatedAt = now
            } else {
                let stored = StoredSession(
                    id: session.id,
                    profileID: profileID,
                    title: session.title,
                    model: session.model,
                    source: session.source,
                    lastActive: session.lastActive ?? 0,
                    updatedAt: now
                )
                context.insert(stored)
                byID[session.id] = stored
            }
        }
        try? context.save()
    }

    /// Removes a session and its messages (cascade) from the local store.
    func deleteSession(id: String, profileID: String) {
        let predicate = #Predicate<StoredSession> {
            $0.id == id && $0.profileID == profileID
        }
        let descriptor = FetchDescriptor<StoredSession>(predicate: predicate)
        guard let matches = try? context.fetch(descriptor) else { return }
        for stored in matches { context.delete(stored) }
        try? context.save()
    }

    // MARK: - Mapping: StoredMessage → TimelineMessage

    private func toTimelineMessage(_ stored: StoredMessage) -> TimelineMessage? {
        let toolCalls: [WireToolCall]? = stored.toolCallsJSON.flatMap {
            try? Self.toolCallDecoder.decode([WireToolCall].self, from: Data($0.utf8))
        }
        let message = HermesMessage(
            id: stored.serverID,
            sessionId: stored.sessionID,
            role: stored.role,
            content: stored.content,
            toolCalls: toolCalls,
            toolCallId: stored.toolCallID,
            toolName: stored.toolName,
            timestamp: stored.timestamp,
            finishReason: stored.finishReason,
            reasoning: stored.reasoning,
            reasoningContent: stored.reasoningContent
        )
        // Reconstruct with the stored localID so the SwiftUI identity stays stable.
        guard let uuid = UUID(uuidString: stored.localID) else { return nil }
        return TimelineMessage(storedLocalID: uuid, message: message)
    }

    // MARK: - Mapping: TimelineMessage → StoredMessage

    private func toStoredMessage(
        _ tl: TimelineMessage,
        sessionID: String,
        profileID: String,
        orderIndex: Int
    ) -> StoredMessage {
        StoredMessage(
            localID: tl.localID.uuidString,
            serverID: tl.message.id,
            sessionID: sessionID,
            profileID: profileID,
            role: tl.message.role,
            content: tl.message.content,
            reasoning: tl.message.reasoning,
            reasoningContent: tl.message.reasoningContent,
            toolCallsJSON: encodeToolCalls(tl.message.toolCalls),
            toolCallID: tl.message.toolCallId,
            toolName: tl.message.toolName,
            timestamp: tl.message.timestamp ?? Date.now.timeIntervalSince1970,
            finishReason: tl.message.finishReason,
            orderIndex: orderIndex,
            updatedAt: Date.now.timeIntervalSince1970
        )
    }

    /// Updates a StoredMessage in place from a TimelineMessage, preserving the SwiftData object identity.
    private func apply(_ tl: TimelineMessage, orderIndex: Int, to stored: StoredMessage) {
        stored.serverID = tl.message.id
        stored.role = tl.message.role
        stored.content = tl.message.content
        stored.reasoning = tl.message.reasoning
        stored.reasoningContent = tl.message.reasoningContent
        stored.toolCallsJSON = encodeToolCalls(tl.message.toolCalls)
        stored.toolCallID = tl.message.toolCallId
        stored.toolName = tl.message.toolName
        stored.timestamp = tl.message.timestamp ?? stored.timestamp
        stored.finishReason = tl.message.finishReason
        stored.isComplete = tl.message.finishReason != nil
        stored.orderIndex = orderIndex
        stored.updatedAt = Date.now.timeIntervalSince1970
    }

    private func encodeToolCalls(_ calls: [WireToolCall]?) -> String? {
        guard let calls, !calls.isEmpty,
              let data = try? Self.toolCallEncoder.encode(calls)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Mapping: StoredSession → Session

    private func toSession(_ stored: StoredSession) -> Session {
        Session(
            id: stored.id,
            title: stored.title,
            source: stored.source,
            model: stored.model,
            startedAt: nil,
            lastActive: stored.lastActive,
            messageCount: nil,
            toolCallCount: nil,
            preview: nil,
            parentSessionId: nil,
            inputTokens: nil,
            outputTokens: nil
        )
    }
}
