import SwiftUI

#if DEBUG
#Preview("ChatView") {
    NavigationStack {
        ChatView(session: ChatView.previewSession)
            .environment(ChatView.previewAppModel)
    }
}

@MainActor
private extension ChatView {
    static var previewSession: Session {
        Session(
            id: "preview-session",
            title: "Hermes Check-In",
            source: "preview",
            model: "hermes-agent",
            startedAt: Date.now.addingTimeInterval(-900).timeIntervalSince1970,
            lastActive: Date.now.timeIntervalSince1970,
            messageCount: 4,
            toolCallCount: 1,
            preview: "Summarize the latest session telemetry.",
            parentSessionId: nil,
            inputTokens: 742,
            outputTokens: 418
        )
    }

    static var previewAppModel: AppModel {
        let profile = ServerProfile(
            id: UUID(uuidString: "D84F3F2B-7D6F-44F6-8F58-93E57D0B6C42")!,
            name: "Preview Hermes",
            url: URL(string: "http://localhost:8000")!,
            apiKey: "preview-key"
        )
        let defaults = UserDefaults(suiteName: "ai.talaria.preview") ?? .standard
        let preferences = AppPreferences(defaults: defaults)
        preferences.setDefaultModelID("hermes-agent", for: profile.id)

        let appModel = AppModel(
            profile: profile,
            preferences: preferences,
            profileStore: ServerProfileStore()
        )
        let store = appModel.openChat(for: previewSession)
        store.timeline = previewTimeline
        return appModel
    }

    static var previewTimeline: [TimelineMessage] {
        [
            previewMessage(
                id: 1,
                role: "user",
                content: "Can you summarize the latest session telemetry and call out anything unusual?",
                timestampOffset: -720
            ),
            previewMessage(
                id: 2,
                role: "assistant",
                content: """
                The session looks healthy overall.

                - Streaming is active and responding within the expected window.
                - Tool calls completed successfully.
                - The only oddity is a short burst of retryable network warnings.
                """,
                timestampOffset: -660,
                toolCalls: [
                    WireToolCall(
                        id: "call-preview-telemetry",
                        callId: nil,
                        type: "function",
                        function: .init(
                            name: "mcp_hermes_logs_query",
                            arguments: "{\"range\":\"24h\",\"level\":\"warning\"}"
                        )
                    )
                ],
                reasoning: "Checked health, warning-level logs, and recent tool completion events before summarizing."
            ),
            previewMessage(
                id: 3,
                role: "tool",
                content: "Scanned 42 warning events. 39 were transient reconnects; 3 were slow response warnings under 1.4s.",
                timestampOffset: -620,
                toolCallID: "call-preview-telemetry",
                toolName: "mcp_hermes_logs_query"
            ),
            previewMessage(
                id: 4,
                role: "user",
                content: "Great. Draft a short note I can send to the team.",
                timestampOffset: -60
            ),
        ]
    }

    static func previewMessage(
        id: Int,
        role: String,
        content: String?,
        timestampOffset: TimeInterval,
        toolCalls: [WireToolCall]? = nil,
        toolCallID: String? = nil,
        toolName: String? = nil,
        reasoning: String? = nil
    ) -> TimelineMessage {
        TimelineMessage(
            message: HermesMessage(
                id: id,
                sessionId: previewSession.id,
                role: role,
                content: content,
                toolCalls: toolCalls,
                toolCallId: toolCallID,
                toolName: toolName,
                timestamp: Date.now.addingTimeInterval(timestampOffset).timeIntervalSince1970,
                finishReason: role == "assistant" ? "stop" : nil,
                reasoning: reasoning,
                reasoningContent: nil
            )
        )
    }
}
#endif
