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

    /// The model that produced this turn's response, shown beside the copy button.
    /// Accurate per-turn within a live session (the app sets the global to the
    /// session's model before each turn). Falls back to the session's current
    /// model for turns reloaded from the server, which doesn't persist this.
    var assistantModelID: String?

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
    /// True while recovering a turn whose live stream dropped (app suspended,
    /// request timeout, network blip) by polling the server for the result.
    var reconnecting: Bool = false
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
    private var recoveryTask: Task<Void, Never>?
    /// True once a run has started server-side but hasn't been finalized yet.
    /// Drives recovery on re-entry/foreground; stays set across navigation so a
    /// dropped stream can be picked back up.
    private var awaitingResult = false
    /// Reentrancy guard so only one recovery poll runs at a time.
    private var recovering = false

    /// How long to actively poll for a dropped run's result. Generous because
    /// agent runs with tool loops can take minutes; re-entering the chat retries.
    private static let recoveryWindow: TimeInterval = 360

    private let client: HermesClient
    private let onRunCompleted: @MainActor @Sendable (String) -> Void
    /// Called at the start of each turn. Points the server's global model at this
    /// session's chosen model (so the session uses it) and returns that model id,
    /// which is recorded for the turn's response label. See
    /// `AppModel.prepareSessionModelForTurn`.
    private let onTurnStart: (@MainActor @Sendable () async -> String?)?
    /// The session's current model id, used to label turns the server gave us back
    /// without per-message model info (reloads). See `AppModel.sessionModelID`.
    private let sessionModelID: (@MainActor @Sendable () -> String?)?
    /// App-wide gate serializing the model-set + run-start window across chats, so
    /// concurrent turns can't clobber each other's global model. See `ModelGate`.
    private let modelGate: ModelGate?

    /// Model used for each completed turn, keyed by the turn's order index. Kept
    /// here (not on the wire message, which has no model field) so labels stay
    /// correct across the per-turn timeline rebuilds that `runCompleted` triggers.
    private var turnModelByIndex: [Int: String] = [:]
    /// Model resolved for the in-flight turn (set by `onTurnStart`).
    private var currentTurnModelID: String?

    init(
        client: HermesClient,
        sessionID: String,
        onRunCompleted: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        onTurnStart: (@MainActor @Sendable () async -> String?)? = nil,
        sessionModelID: (@MainActor @Sendable () -> String?)? = nil,
        modelGate: ModelGate? = nil
    ) {
        self.client = client
        self.sessionID = sessionID
        self.onRunCompleted = onRunCompleted
        self.onTurnStart = onTurnStart
        self.sessionModelID = sessionModelID
        self.modelGate = modelGate
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
            adoptExternalRunIfNeeded(from: messages)
        } catch {
            let mapped = HermesError(error)
            // Cancellation is routine (view churn / navigation); never surface it to the user.
            guard mapped != .cancelled else { return }
            lastError = mapped
        }
    }

    // MARK: - Sending

    func send(_ text: String, attachments: [ComposerAttachment] = []) async {
        // Images ride inline as image_url parts; documents are uploaded to the
        // Talaria plugin and referenced by their on-host path so the agent's
        // read_file / web_extract tools can read them.
        let imageData = attachments.compactMap { attachment -> Data? in
            guard let data = attachment.data, HermesChatInput.imageMIMEType(for: data) != nil else { return nil }
            return data
        }
        let fileAttachments = attachments.filter { attachment in
            guard let data = attachment.data else { return false }
            return HermesChatInput.imageMIMEType(for: data) == nil
        }
        let userMsg = HermesMessage(
            id: nil, sessionId: sessionID, role: "user", content: text,
            toolCalls: nil, toolCallId: nil, toolName: nil,
            timestamp: Date.now.timeIntervalSince1970, finishReason: nil,
            reasoning: nil, reasoningContent: nil
        )
        timeline.append(TimelineMessage(
            message: userMsg,
            imageAttachments: imageData,
            fileAttachmentNames: fileAttachments.map(\.name)
        ))
        working = true
        reconnecting = false
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
        awaitingResult = true
        recovering = false
        rebuildTurns()

        // Upload documents before opening the stream. On failure, surface the
        // error and abort the turn rather than sending a dangling reference.
        var uploadIDs: [String] = []
        var fileRefs: [String] = []
        do {
            for attachment in fileAttachments {
                guard let data = attachment.data else { continue }
                let uploaded = try await client.uploadAttachment(
                    data: data,
                    filename: attachment.name,
                    contentType: nil,
                    sessionID: sessionID
                )
                uploadIDs.append(uploaded.id)
                fileRefs.append(
                    "[Attachment \"\(uploaded.filename)\" saved on this host at \(uploaded.agentReadablePath). "
                    + "Use read_file or web_extract to read it.]"
                )
            }
        } catch {
            lastError = HermesError(error)
            working = false
            awaitingResult = false
            rebuildTurns()
            return
        }

        let agentText = ([text] + fileRefs).filter { !$0.isEmpty }.joined(separator: "\n\n")
        let input = HermesChatInput.make(text: agentText, attachments: attachments)

        recoveryTask?.cancel()
        recoveryTask = nil
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else { return }
            await self.runStream(input: input, uploadIDs: uploadIDs)
        }
    }

    /// Appends a local command/result exchange to the timeline without contacting
    /// the agent — used by slash commands the app handles itself (e.g. `/status`).
    /// The pair renders as a normal user turn with an assistant reply; it is
    /// local-only and disappears on reload, which is fine for ephemeral commands.
    func appendLocalExchange(command: String, result: String) {
        let now = Date.now.timeIntervalSince1970
        let user = HermesMessage(
            id: nil, sessionId: sessionID, role: "user", content: command,
            toolCalls: nil, toolCallId: nil, toolName: nil,
            timestamp: now, finishReason: nil, reasoning: nil, reasoningContent: nil
        )
        let assistant = HermesMessage(
            id: nil, sessionId: sessionID, role: "assistant", content: result,
            toolCalls: nil, toolCallId: nil, toolName: nil,
            timestamp: now, finishReason: "stop", reasoning: nil, reasoningContent: nil
        )
        timeline.append(TimelineMessage(message: user))
        timeline.append(TimelineMessage(message: assistant))
        rebuildTurns()
    }

    private func runStream(input: HermesChatInput, uploadIDs: [String] = []) async {
        // Best-effort cleanup of uploaded documents once the run is fully done
        // (this function only returns after completion or recovery), so we don't
        // pull a file out from under an in-flight server-side read.
        defer {
            if !uploadIDs.isEmpty {
                Task { [client] in
                    for id in uploadIDs { try? await client.deleteAttachment(id: id) }
                }
            }
        }
        // Acquire the kickoff gate: set the global model and start the run under
        // app-wide mutual exclusion so a concurrent chat can't clobber the global
        // before this run binds it. Release the instant the run starts (first
        // event) — the run's model is then frozen, so generation streams unguarded
        // and other chats stay parallel. See ModelGate.
        await modelGate?.acquire()
        var gateReleased = false
        func releaseGate() {
            guard !gateReleased else { return }
            gateReleased = true
            modelGate?.release()
        }

        // Point the server's global model at this session's model before the turn
        // (Hermes resolves the model fresh each turn), and record it for the
        // response label keyed by this turn's order index so it survives rebuilds.
        currentTurnModelID = await onTurnStart?() ?? nil
        if let model = currentTurnModelID {
            turnModelByIndex[lastTurnIndex] = model
        }
        guard !Task.isCancelled else { releaseGate(); working = false; awaitingResult = false; return }

        let stream = client.sessionChatStream(sessionID: sessionID, input: input)
        do {
            for try await event in stream {
                if Task.isCancelled { releaseGate(); return }
                await process(event)
                // Run is accepted and its model is now bound — free the gate so the
                // next queued chat can kick off while this one keeps streaming.
                releaseGate()
            }
            releaseGate()
        } catch {
            releaseGate()
            // A cancelled task means the user stopped or sent again — not a drop.
            if Task.isCancelled {
                working = false
                awaitingResult = false
                return
            }
            let mapped = HermesError(error)
            // Recover only once a run actually started server-side. If the request
            // itself failed (server down, bad URL, auth), surface it immediately —
            // there's nothing running to reconnect to.
            if currentRunID == nil || mapped == .unauthorized || mapped == .notFound {
                lastError = mapped
                working = false
                awaitingResult = false
                rebuildTurns()
                return
            }
            // Connection dropped (timeout / app suspension / network blip). The run
            // keeps executing on the server, so fall through and recover the result.
        }

        if receivedRunCompleted && !needsCompletionRefresh {
            if working {
                finalizeStreamingResponseIfNeeded()
                working = false
            }
            awaitingResult = false
            rebuildTurns()
            return
        }

        // Stream ended without a usable completion (dropped connection, or a clean
        // EOF mid-run). Recover the finished transcript by polling the server.
        if currentRunID != nil || needsCompletionRefresh {
            await recoverInterruptedRun()
        } else {
            finalizeStreamingResponseIfNeeded()
            working = false
            awaitingResult = false
            rebuildTurns()
        }
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
        recoveryTask?.cancel()
        recoveryTask = nil
        working = false
        reconnecting = false
        recovering = false
        awaitingResult = false
        rebuildTurns()
        if let runID = currentRunID {
            Task {
                try? await client.stopRun(runID: runID)
            }
        }
    }

    // MARK: - Event application

    func apply(_ event: HermesStreamEvent) {
        var shouldMarkStreamingLayoutChanged = false

        defer {
            rebuildTurns()
            if shouldMarkStreamingLayoutChanged {
                markStreamingLayoutChanged(force: true)
            }
        }

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
            shouldMarkStreamingLayoutChanged = true

        case .toolCompleted(let msgID, let name):
            currentStreamMsgID = msgID
            if let idx = liveToolIndex(messageID: msgID, name: name) {
                liveTools[idx].status = .completed
                syncLiveToolBlock(liveTools[idx])
                shouldMarkStreamingLayoutChanged = true
            }

        case .toolProgress(let msgID, let name, let text):
            currentStreamMsgID = msgID
            if let idx = liveToolIndex(messageID: msgID, name: name) {
                liveTools[idx].progress = (liveTools[idx].progress ?? "") + text
                syncLiveToolBlock(liveTools[idx])
                shouldMarkStreamingLayoutChanged = true
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
                shouldMarkStreamingLayoutChanged = true
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
            awaitingResult = false
            streamingText.removeAll()
            streamingThinking.removeAll()
            liveTools.removeAll()
            liveBlocks.removeAll()
            currentStreamMsgID = nil
            onRunCompleted(sessionID)

        case .runFailed(let error):
            lastError = HermesError.network(error)
            working = false
            reconnecting = false
            awaitingResult = false
            streamingText.removeAll()
            streamingThinking.removeAll()
            liveTools.removeAll()
            liveBlocks.removeAll()
        }
    }

    // MARK: - Turns

    /// Order index of the most recent turn (the user message just sent).
    private var lastTurnIndex: Int {
        max(0, timeline.lazy.filter { $0.message.role == "user" }.count - 1)
    }

    private func rebuildTurns() {
        var result: [ChatTurn] = []
        var i = 0
        var turnIndex = 0
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
            // The model that produced this turn's reply: the one recorded when the
            // turn ran, the in-flight model for a live turn, else the session's
            // current model (server reloads carry no per-message model).
            let turnModel = turnModelByIndex[turnIndex]
                ?? (liveTurn ? currentTurnModelID : nil)
                ?? sessionModelID?()

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
                assistantModelID: turnModel,
                streamingThinking: streamThinking,
                isSending: sending
            ))
            i = j
            turnIndex += 1
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
        reconnecting = false
        awaitingResult = false
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

    // MARK: - Recovery (dropped stream)

    /// Resumes recovery when the chat reappears or the app returns to the
    /// foreground while a run is still outstanding (its live stream was dropped).
    /// Safe to call repeatedly: it no-ops unless there's an unfinished run and no
    /// recovery is already in flight.
    func recoverIfNeeded() {
        guard awaitingResult, !recovering else { return }
        recoveryTask?.cancel()
        recoveryTask = Task { [weak self] in
            await self?.recoverInterruptedRun()
            self?.recoveryTask = nil
        }
    }

    /// If another client started a run, `/messages` can show the user's prompt
    /// before the final assistant reply has landed. We can't attach to that
    /// stream, so adopt it as recoverable work and poll for the final transcript.
    private func adoptExternalRunIfNeeded(from messages: [HermesMessage]) {
        guard !working, !awaitingResult, hasPendingAssistantReply(in: messages) else { return }

        awaitingResult = true
        receivedRunCompleted = false
        needsCompletionRefresh = true
        currentRunID = nil
        lastError = nil
        recoverIfNeeded()
    }

    /// Recovers a turn whose live stream dropped before completing (app suspended,
    /// request timeout, network blip, or external client handoff). Session-stream runs can't be re-attached —
    /// the Runs control plane doesn't track them (`/v1/runs/{id}` 404s) — but they
    /// keep running server-side and the finished transcript lands in `/messages`.
    /// So poll until the assistant's reply appears, then finalize. The drop itself
    /// is never surfaced as an error.
    private func recoverInterruptedRun() async {
        guard awaitingResult, !recovering else { return }
        recovering = true
        reconnecting = true
        working = true
        rebuildTurns()
        defer {
            recovering = false
            reconnecting = false
        }

        let deadline = Date.now.addingTimeInterval(Self.recoveryWindow)
        var delay: Duration = .seconds(2)
        while Date.now < deadline {
            if Task.isCancelled { return }
            if let messages = try? await client.messages(sessionID: sessionID),
               hasCompletedAssistantReply(in: messages) {
                await finalizeFromMessages(messages)
                return
            }
            try? await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(8))
        }

        // Gave up actively polling. The turn stays recoverable (reopening or
        // foregrounding the chat retries via `recoverIfNeeded()`); stop the spinner
        // and leave a gentle, non-fatal note rather than a scary timeout error.
        guard !receivedRunCompleted else { return }
        working = false
        lastError = .network("Lost the connection while the agent was still responding. Reopen the chat to load the finished reply.")
        rebuildTurns()
    }

    /// The run is finished once a visible assistant reply exists after the last
    /// user message. The server persists the whole transcript atomically on
    /// completion — there are no partial assistant messages mid-run — so the
    /// reply's presence is a reliable "done" signal.
    private func hasCompletedAssistantReply(in messages: [HermesMessage]) -> Bool {
        guard let lastUserIdx = messages.lastIndex(where: { $0.role == "user" }) else {
            return messages.contains { $0.role == "assistant" && $0.hasVisibleContent }
        }
        let start = messages.index(after: lastUserIdx)
        guard start < messages.endIndex else { return false }
        return messages[start...].contains { $0.role == "assistant" && $0.hasVisibleContent }
    }

    private func hasPendingAssistantReply(in messages: [HermesMessage]) -> Bool {
        guard let lastUserIdx = messages.lastIndex(where: { $0.role == "user" }) else {
            return false
        }
        let start = messages.index(after: lastUserIdx)
        guard start < messages.endIndex else { return true }
        return !messages[start...].contains { $0.role == "assistant" && $0.hasVisibleContent }
    }

    /// Finalizes the in-flight turn from the authoritative `/messages` list.
    /// `/messages` is the full conversation, so the timeline is replaced wholesale
    /// (like `load()`), not reconciled. The final answer is revealed with the
    /// usual streaming animation first so it doesn't pop in abruptly.
    private func finalizeFromMessages(_ messages: [HermesMessage]) async {
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
        }

        receivedRunCompleted = true
        needsCompletionRefresh = false
        awaitingResult = false
        working = false
        reconnecting = false
        lastError = nil
        streamingText.removeAll()
        streamingThinking.removeAll()
        liveTools.removeAll()
        liveBlocks.removeAll()
        currentStreamMsgID = nil
        rebuildTurns()
        onRunCompleted(sessionID)
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
