import Foundation
import Observation

// MARK: - Live tool

struct LiveTool: Identifiable, Sendable {
    enum Status: Sendable { case running, completed }
    let id: String
    let messageID: String
    let name: String
    var arguments: String?
    var progress: String?
    var status: Status
}

// MARK: - Live block

/// Mutable, event-ordered counterpart to `ChatTurn.Block` used while a turn streams.
private enum LiveBlock {
    case text(id: String, content: String)
    case tool(LiveTool)
}

// MARK: - Chat turn

struct ChatTurn: Identifiable, Sendable {
    struct ToolEntry: Identifiable, Sendable {
        let id: String
        let name: String
        var arguments: String?
        var output: String?
        var progress: String?
        var isRunning: Bool
    }

    /// An ordered renderable unit within a turn. Building the turn as a single
    /// ordered list (rather than separate text/tool arrays) keeps tool calls
    /// interleaved with assistant text in the order they actually occurred.
    enum Block: Identifiable, Sendable {
        case text(id: String, content: String, isStreaming: Bool)
        case tool(ToolEntry)

        var id: String {
            switch self {
            case .text(let id, _, _): return "text:\(id)"
            case .tool(let entry): return "tool:\(entry.id)"
            }
        }
    }

    let id: UUID
    let userMessage: TimelineMessage
    var assistantMessages: [TimelineMessage]
    var blocks: [Block]

    // Streaming-only (nil on finalized turns)
    var streamingThinking: String?

    /// True for the optimistic user message that hasn't been acknowledged by the server yet.
    var isSending: Bool = false

    var hasLiveContent: Bool {
        !blocks.isEmpty || streamingThinking?.isEmpty == false
    }
}

// MARK: - ChatStore

@MainActor
@Observable
final class ChatStore {
    let sessionID: String

    var timeline: [TimelineMessage] = []
    private(set) var turns: [ChatTurn] = []
    var working: Bool = false
    var loading: Bool = false
    var lastError: HermesError?
    var currentRunID: String?
    var lastUsage: TokenUsage?
    private(set) var streamingRevision = 0

    // Ephemeral streaming state
    private var streamingText: [String: String] = [:]
    private var streamingThinking: [String: String] = [:]
    private var liveTools: [LiveTool] = []
    /// Ordered text/tool blocks for the in-flight turn, captured in event order.
    private var liveBlocks: [LiveBlock] = []
    /// Monotonic id source for live text blocks, so a new text segment after a
    /// tool call gets a distinct identity instead of merging into the prior one.
    private var liveTextSeq = 0
    private var currentStreamMsgID: String?
    private var receivedRunCompleted = false
    private var needsCompletionRefresh = false
    private var streamingLayoutTick = 0

    private var streamTask: Task<Void, Never>?

    private let client: HermesClient
    private let onRunCompleted: @MainActor @Sendable (String) -> Void

    init(
        client: HermesClient,
        sessionID: String,
        onRunCompleted: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) {
        self.client = client
        self.sessionID = sessionID
        self.onRunCompleted = onRunCompleted
    }

    // MARK: - Loading

    func load() async {
        loading = true
        lastError = nil
        defer { loading = false }
        do {
            let messages = try await client.messages(sessionID: sessionID)
            timeline = messages.map { TimelineMessage(message: $0) }
            rebuildTurns()
        } catch {
            let mapped = HermesError(error)
            // Cancellation is routine (view churn / navigation); never surface it to the user.
            guard mapped != .cancelled else { return }
            lastError = mapped
        }
    }

    // MARK: - Sending

    func send(_ text: String) async {
        let userMsg = HermesMessage(
            id: nil, sessionId: sessionID, role: "user", content: text,
            toolCalls: nil, toolCallId: nil, toolName: nil,
            timestamp: Date.now.timeIntervalSince1970, finishReason: nil,
            reasoning: nil, reasoningContent: nil
        )
        timeline.append(TimelineMessage(message: userMsg))
        working = true
        lastError = nil
        currentRunID = nil
        streamingText.removeAll()
        streamingThinking.removeAll()
        liveTools.removeAll()
        liveBlocks.removeAll()
        liveTextSeq = 0
        currentStreamMsgID = nil
        receivedRunCompleted = false
        needsCompletionRefresh = false
        rebuildTurns()

        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else { return }
            await self.runStream(text: text)
        }
    }

    private func runStream(text: String) async {
        let stream = client.sessionChatStream(sessionID: sessionID, input: text)
        var shouldRefreshAfterStream = false
        do {
            for try await event in stream {
                guard !Task.isCancelled else { break }
                await process(event)
            }
            shouldRefreshAfterStream = !receivedRunCompleted || needsCompletionRefresh
        } catch is CancellationError {
            working = false
        } catch let hermesErr as HermesError where hermesErr == .cancelled {
            working = false
        } catch {
            lastError = HermesError(error)
            working = false
        }

        if shouldRefreshAfterStream {
            let refreshed = await refreshTimelineAfterStream()
            if !refreshed {
                finalizeStreamingResponseIfNeeded()
            }
        }

        // Safety net: if run.completed was never received/parsed, clear the working flag.
        if working {
            finalizeStreamingResponseIfNeeded()
            working = false
        }
        rebuildTurns()
    }

    private func process(_ event: HermesStreamEvent) async {
        switch event {
        case .assistantDelta(let msgID, let text):
            await revealAssistantText(messageID: msgID, text: text)

        case .assistantCompleted(let msgID, let content, let reasoning):
            await finishAssistantMessage(messageID: msgID, content: content, reasoning: reasoning)

        case .thinkingDelta(let msgID, let text):
            await revealThinkingText(messageID: msgID, text: text)

        case .runCompleted(let messages, let usage):
            await finishRun(messages: messages, usage: usage)

        default:
            apply(event)
            if event.isDiscreteStreamingEvent {
                await yieldStreamingFrame()
            }
        }
    }

    // MARK: - Stop

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        working = false
        rebuildTurns()
        if let runID = currentRunID {
            Task {
                try? await client.stopRun(runID: runID)
            }
        }
    }

    // MARK: - Event application

    func apply(_ event: HermesStreamEvent) {
        defer { rebuildTurns() }

        switch event {
        case .runStarted(let runID):
            currentRunID = runID

        case .messageStarted(let msgID):
            currentStreamMsgID = msgID

        case .assistantDelta(let msgID, let text):
            currentStreamMsgID = msgID
            streamingText[msgID, default: ""] += text

        case .assistantCompleted(let msgID, let content, let reasoning):
            currentStreamMsgID = msgID.nilIfEmpty ?? currentStreamMsgID
            finalizeAssistantMessage(
                messageID: msgID,
                content: content,
                reasoning: reasoning
            )

        case .thinkingDelta(let msgID, let text):
            currentStreamMsgID = msgID
            streamingThinking[msgID, default: ""] += text

        case .toolStarted(let msgID, let name, let args):
            currentStreamMsgID = msgID
            let tool = LiveTool(
                id: "\(msgID.nilIfEmpty ?? "stream")|\(name)|\(UUID().uuidString.prefix(8))",
                messageID: msgID,
                name: name,
                arguments: args,
                progress: nil,
                status: .running
            )
            liveTools.append(tool)
            liveBlocks.append(.tool(tool))

        case .toolCompleted(let msgID, let name):
            currentStreamMsgID = msgID
            if let idx = liveToolIndex(messageID: msgID, name: name) {
                liveTools[idx].status = .completed
                syncLiveToolBlock(liveTools[idx])
            }

        case .toolProgress(let msgID, let name, let text):
            currentStreamMsgID = msgID
            if let idx = liveToolIndex(messageID: msgID, name: name) {
                liveTools[idx].progress = (liveTools[idx].progress ?? "") + text
                syncLiveToolBlock(liveTools[idx])
            } else {
                let tool = LiveTool(
                    id: "\(msgID.nilIfEmpty ?? "stream")|\(name)|\(UUID().uuidString.prefix(8))",
                    messageID: msgID,
                    name: name,
                    arguments: nil,
                    progress: text,
                    status: .running
                )
                liveTools.append(tool)
                liveBlocks.append(.tool(tool))
            }

        case .approvalRequired, .unknown:
            break

        case .runCompleted(let messages, let usage):
            receivedRunCompleted = true
            needsCompletionRefresh = messages.isEmpty
            if !messages.isEmpty {
                reconcile(with: messages)
            }
            lastUsage = usage
            working = false
            streamingText.removeAll()
            streamingThinking.removeAll()
            liveTools.removeAll()
            liveBlocks.removeAll()
            currentStreamMsgID = nil
            onRunCompleted(sessionID)

        case .runFailed(let error):
            lastError = HermesError.network(error)
            working = false
            streamingText.removeAll()
            streamingThinking.removeAll()
            liveTools.removeAll()
            liveBlocks.removeAll()
        }
    }

    // MARK: - Turns

    private func rebuildTurns() {
        var result: [ChatTurn] = []
        var i = 0
        while i < timeline.count {
            let msg = timeline[i]
            guard msg.message.role == "user" else { i += 1; continue }

            var assistantMsgs: [TimelineMessage] = []
            var j = i + 1
            while j < timeline.count, timeline[j].message.role != "user" {
                if timeline[j].message.role == "assistant" {
                    assistantMsgs.append(timeline[j])
                }
                j += 1
            }

            let isLastTurn = j >= timeline.count
            let liveTurn = isLastTurn && working

            // Ordered render blocks: for the in-flight turn use the event-ordered
            // live blocks; for finalized turns walk the timeline slice in order so
            // tool calls stay interleaved with assistant text.
            let blocks = liveTurn ? currentLiveBlocks() : finalizedBlocks(in: i..<j)
            let streamThinking = liveTurn ? activeStreamingThinking : nil
            // The just-sent message is "sending" until the server starts the run (runStarted → currentRunID).
            let sending = liveTurn && currentRunID == nil && blocks.isEmpty

            result.append(ChatTurn(
                id: msg.localID,
                userMessage: msg,
                assistantMessages: assistantMsgs,
                blocks: blocks,
                streamingThinking: streamThinking,
                isSending: sending
            ))
            i = j
        }
        turns = result
    }

    /// Ordered blocks for a finalized turn, walking `timeline[range]` in order.
    private func finalizedBlocks(in range: Range<Int>) -> [ChatTurn.Block] {
        var blocks: [ChatTurn.Block] = []
        for k in range {
            let msg = timeline[k].message
            guard msg.role == "assistant" else { continue }

            if let content = msg.content, !content.isEmpty {
                blocks.append(.text(
                    id: timeline[k].id.uuidString,
                    content: content,
                    isStreaming: msg.finishReason == nil
                ))
            }
            for tc in msg.toolCalls ?? [] {
                let output = timeline[range].first(where: { $0.message.toolCallId == tc.id })?.message.content
                blocks.append(.tool(ChatTurn.ToolEntry(
                    id: tc.id,
                    name: tc.function.name,
                    arguments: tc.function.arguments,
                    output: output,
                    progress: nil,
                    isRunning: false
                )))
            }
        }
        return blocks
    }

    /// Render blocks for the in-flight turn, converted from the event-ordered live blocks.
    private func currentLiveBlocks() -> [ChatTurn.Block] {
        liveBlocks.map { block in
            switch block {
            case .text(let id, let content):
                return .text(id: id, content: content, isStreaming: true)
            case .tool(let tool):
                return .tool(ChatTurn.ToolEntry(
                    id: tool.id,
                    name: tool.name,
                    arguments: tool.arguments,
                    output: nil,
                    progress: tool.progress,
                    isRunning: tool.status == .running
                ))
            }
        }
    }

    /// Appends a streamed chunk to the trailing live text block, starting a fresh
    /// block when the previous block is a tool call so text stays in event order.
    private func appendLiveText(_ chunk: String) {
        if case .text(let id, let content)? = liveBlocks.last {
            liveBlocks[liveBlocks.count - 1] = .text(id: id, content: content + chunk)
        } else {
            liveTextSeq += 1
            liveBlocks.append(.text(id: "live-text-\(liveTextSeq)", content: chunk))
        }
    }

    /// Seeds live blocks with the tool calls (and any earlier assistant text) from a
    /// completed run, so they're on screen in order *before* the final answer streams
    /// in — otherwise they pop in only after the message finishes revealing. Only runs
    /// when nothing streamed live, so it never disturbs the live event path.
    private func seedLiveBlocksFromCompletion(_ messages: [HermesMessage]) {
        guard liveBlocks.isEmpty,
              let finalIdx = messages.lastIndex(where: { $0.role == "assistant" && $0.hasVisibleContent })
        else { return }

        var seeded: [LiveBlock] = []
        for msg in messages[..<finalIdx] where msg.role == "assistant" {
            if let content = msg.content, !content.isEmpty {
                liveTextSeq += 1
                seeded.append(.text(id: "seed-text-\(liveTextSeq)", content: content))
            }
            for tc in msg.toolCalls ?? [] {
                seeded.append(.tool(LiveTool(
                    id: tc.id,
                    messageID: "",
                    name: tc.function.name,
                    arguments: tc.function.arguments,
                    progress: nil,
                    status: .completed
                )))
            }
        }

        guard !seeded.isEmpty else { return }
        liveBlocks = seeded
    }

    /// Mirrors an updated live tool into its ordered block.
    private func syncLiveToolBlock(_ tool: LiveTool) {
        if let idx = liveBlocks.firstIndex(where: {
            if case .tool(let existing) = $0 { return existing.id == tool.id }
            return false
        }) {
            liveBlocks[idx] = .tool(tool)
        } else {
            liveBlocks.append(.tool(tool))
        }
    }

    /// Lightweight live-turn refresh used on the high-frequency text reveal path,
    /// avoiding a full `rebuildTurns()` per character chunk.
    private func refreshLiveTurnBlocks() {
        guard working, let idx = turns.indices.last else {
            rebuildTurns()
            return
        }
        turns[idx].blocks = currentLiveBlocks()
        turns[idx].streamingThinking = activeStreamingThinking
        turns[idx].isSending = currentRunID == nil && turns[idx].blocks.isEmpty
        markStreamingLayoutChanged()
    }

    private func markStreamingLayoutChanged(force: Bool = false) {
        streamingLayoutTick &+= 1
        guard force || streamingLayoutTick.isMultiple(of: 4) else { return }
        streamingRevision &+= 1
    }

    // MARK: - Reconcile on runCompleted

    private func reconcile(with messages: [HermesMessage]) {
        // Keep everything up to and including the last user message; replace assistant/tool after it
        if let lastUserIdx = timeline.indices.reversed().first(where: { timeline[$0].message.role == "user" }) {
            let keepCount = lastUserIdx + 1
            timeline.removeLast(timeline.count - keepCount)
        }
        for msg in messages {
            guard msg.role != "user" else { continue }
            timeline.append(TimelineMessage(message: msg))
        }
    }

    private func finalizeAssistantMessage(messageID: String, content: String?, reasoning: String?) {
        let resolvedID = messageID.nilIfEmpty ?? currentStreamMsgID ?? ""
        let resolvedContent = content?.nonEmpty ?? streamingText[resolvedID]?.nonEmpty ?? activeStreamingText
        let resolvedReasoning = reasoning?.nonEmpty ?? streamingThinking[resolvedID]?.nonEmpty ?? activeStreamingThinking

        guard resolvedContent?.isEmpty == false || resolvedReasoning?.isEmpty == false else { return }

        upsertAssistantAfterLastUser(HermesMessage(
            id: nil,
            sessionId: sessionID,
            role: "assistant",
            content: resolvedContent,
            toolCalls: nil,
            toolCallId: nil,
            toolName: nil,
            timestamp: Date.now.timeIntervalSince1970,
            finishReason: "stop",
            reasoning: resolvedReasoning,
            reasoningContent: resolvedReasoning
        ))

        if !resolvedID.isEmpty {
            streamingText.removeValue(forKey: resolvedID)
            streamingThinking.removeValue(forKey: resolvedID)
        }
    }

    private func finishAssistantMessage(messageID: String, content: String, reasoning: String?) async {
        let resolvedID = messageID.nilIfEmpty ?? currentStreamMsgID ?? ""
        currentStreamMsgID = resolvedID.nilIfEmpty ?? currentStreamMsgID

        if let remaining = remainingTextToReveal(fullText: content, messageID: resolvedID),
           !remaining.isEmpty {
            await revealAssistantText(messageID: resolvedID, text: remaining)
        }

        finalizeAssistantMessage(messageID: resolvedID, content: content, reasoning: reasoning)
        rebuildTurns()
    }

    private func finishRun(messages: [HermesMessage], usage: TokenUsage?) async {
        receivedRunCompleted = true
        needsCompletionRefresh = messages.isEmpty

        if let finalAssistant = messages.last(where: { $0.role == "assistant" && $0.hasVisibleContent }) {
            seedLiveBlocksFromCompletion(messages)
            await finishAssistantMessage(
                messageID: currentStreamMsgID ?? "",
                content: finalAssistant.content ?? "",
                reasoning: finalAssistant.reasoning ?? finalAssistant.reasoningContent
            )
        }

        if !messages.isEmpty {
            reconcile(with: messages)
        }

        lastUsage = usage
        working = false
        streamingText.removeAll()
        streamingThinking.removeAll()
        liveTools.removeAll()
        liveBlocks.removeAll()
        currentStreamMsgID = nil
        rebuildTurns()
        onRunCompleted(sessionID)
    }

    private func finalizeStreamingResponseIfNeeded() {
        guard let fallback = streamingFallbackMessage(),
              !hasAssistantAfterLastUser
        else { return }
        upsertAssistantAfterLastUser(fallback)
    }

    private func streamingFallbackMessage() -> HermesMessage? {
        let content = activeStreamingText
        let reasoning = activeStreamingThinking
        guard content?.isEmpty == false || reasoning?.isEmpty == false else { return nil }

        return HermesMessage(
            id: nil,
            sessionId: sessionID,
            role: "assistant",
            content: content,
            toolCalls: nil,
            toolCallId: nil,
            toolName: nil,
            timestamp: Date.now.timeIntervalSince1970,
            finishReason: nil,
            reasoning: reasoning,
            reasoningContent: reasoning
        )
    }

    private var hasAssistantAfterLastUser: Bool {
        guard let lastUserIdx = timeline.indices.reversed().first(where: { timeline[$0].message.role == "user" }) else {
            return false
        }
        let start = timeline.index(after: lastUserIdx)
        guard start < timeline.endIndex else { return false }
        return timeline[start...].contains { $0.message.role == "assistant" }
    }

    @discardableResult
    private func upsertAssistantAfterLastUser(_ message: HermesMessage) -> TimelineMessage {
        guard let lastUserIdx = timeline.indices.reversed().first(where: { timeline[$0].message.role == "user" }) else {
            let timelineMessage = TimelineMessage(message: message)
            timeline.append(timelineMessage)
            return timelineMessage
        }

        let start = timeline.index(after: lastUserIdx)
        if start < timeline.endIndex,
           let assistantIdx = timeline[start...].firstIndex(where: { $0.message.role == "assistant" }) {
            timeline[assistantIdx].message = message
            return timeline[assistantIdx]
        } else {
            let timelineMessage = TimelineMessage(message: message)
            timeline.append(timelineMessage)
            return timelineMessage
        }
    }

    private func revealAssistantText(messageID: String, text: String) async {
        guard !text.isEmpty else { return }
        let resolvedID = messageID.nilIfEmpty ?? currentStreamMsgID ?? "stream"
        currentStreamMsgID = resolvedID

        await reveal(text) { chunk in
            streamingText[resolvedID, default: ""] += chunk
            appendLiveText(chunk)
            refreshLiveTurnBlocks()
        }
    }

    private func revealThinkingText(messageID: String, text: String) async {
        guard !text.isEmpty else { return }
        let resolvedID = messageID.nilIfEmpty ?? currentStreamMsgID ?? "stream"
        currentStreamMsgID = resolvedID

        await reveal(text) { chunk in
            streamingThinking[resolvedID, default: ""] += chunk
            refreshLiveTurnBlocks()
        }
    }

    private func reveal(_ text: String, append: (String) -> Void) async {
        var index = text.startIndex
        var remaining = text.count

        while index < text.endIndex {
            guard !Task.isCancelled else { return }

            let chunkSize = revealChunkSize(remainingCharacters: remaining)
            let end = text.index(index, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
            let chunk = String(text[index..<end])
            append(chunk)

            remaining -= chunk.count
            index = end
            await yieldStreamingFrame()
        }
        markStreamingLayoutChanged(force: true)
    }

    private func revealChunkSize(remainingCharacters: Int) -> Int {
        switch remainingCharacters {
        case 0...400:
            6
        case 401...1_600:
            12
        default:
            24
        }
    }

    private func remainingTextToReveal(fullText: String, messageID: String) -> String? {
        guard !fullText.isEmpty else { return nil }
        let currentText = streamingText[messageID]?.nonEmpty ?? activeStreamingText ?? ""
        guard !currentText.isEmpty else { return fullText }
        guard fullText.hasPrefix(currentText) else { return nil }
        return String(fullText.dropFirst(currentText.count))
    }

    private var activeStreamingText: String? {
        activeStreamingValue(from: streamingText)
    }

    private var activeStreamingThinking: String? {
        activeStreamingValue(from: streamingThinking)
    }

    private func activeStreamingValue(from values: [String: String]) -> String? {
        if let currentStreamMsgID,
           let currentValue = values[currentStreamMsgID],
           !currentValue.isEmpty {
            return currentValue
        }
        let combined = values.values.joined()
        return combined.isEmpty ? nil : combined
    }

    private func liveToolIndex(messageID: String, name: String?) -> Int? {
        if let idx = liveTools.indices.last(where: { idx in
            let tool = liveTools[idx]
            guard let name else { return tool.messageID == messageID }
            return tool.messageID == messageID && tool.name == name
        }) {
            return idx
        }

        guard let name else { return nil }
        return liveTools.indices.last(where: { liveTools[$0].name == name })
    }

    private func yieldStreamingFrame() async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(14))
    }

    private func refreshTimelineAfterStream() async -> Bool {
        do {
            let previousTimeline = timeline
            let fallback = streamingFallbackMessage()
            let messages = try await client.messages(sessionID: sessionID)

            if let finalAssistant = messages.last(where: { $0.role == "assistant" && $0.hasVisibleContent }) {
                seedLiveBlocksFromCompletion(messages)
                await finishAssistantMessage(
                    messageID: currentStreamMsgID ?? "",
                    content: finalAssistant.content ?? "",
                    reasoning: finalAssistant.reasoning ?? finalAssistant.reasoningContent
                )
            }

            if messages.contains(where: { $0.role == "user" }) {
                timeline = messages.map { TimelineMessage(message: $0) }
            } else if !hasAssistantAfterLastUser {
                timeline = previousTimeline
            }
            if let fallback, !hasAssistantAfterLastUser {
                upsertAssistantAfterLastUser(fallback)
            }
            streamingText.removeAll()
            streamingThinking.removeAll()
            liveTools.removeAll()
            liveBlocks.removeAll()
            currentStreamMsgID = nil
            receivedRunCompleted = true
            needsCompletionRefresh = false
            rebuildTurns()
            onRunCompleted(sessionID)
            return true
        } catch {
            lastError = HermesError(error)
            return false
        }
    }
}

private extension HermesStreamEvent {
    var isDiscreteStreamingEvent: Bool {
        switch self {
        case .toolStarted, .toolCompleted:
            return true
        case .runStarted, .messageStarted, .assistantDelta, .assistantCompleted, .thinkingDelta, .toolProgress, .approvalRequired, .runCompleted, .runFailed, .unknown:
            return false
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension HermesMessage {
    var hasVisibleContent: Bool {
        content?.isEmpty == false
        || reasoning?.isEmpty == false
        || reasoningContent?.isEmpty == false
    }
}
