import Foundation
import OSLog

enum HermesEventStream {
    private static let log = Logger(subsystem: "ai.talaria.client.ios", category: "HermesEventStream")

    static func make(
        baseURL: URL,
        apiKey: String,
        sessionKey: String,
        sessionID: String,
        input: HermesChatInput
    ) -> AsyncThrowingStream<HermesStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await pump(
                        baseURL: baseURL,
                        apiKey: apiKey,
                        sessionKey: sessionKey,
                        sessionID: sessionID,
                        input: input,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: HermesError.cancelled)
                } catch {
                    continuation.finish(throwing: HermesError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func pump(
        baseURL: URL,
        apiKey: String,
        sessionKey: String,
        sessionID: String,
        input: HermesChatInput,
        continuation: AsyncThrowingStream<HermesStreamEvent, Error>.Continuation
    ) async throws {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = .infinity
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)

        let url = baseURL.appending(path: "/api/sessions/\(sessionID)/chat/stream")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(sessionKey, forHTTPHeaderField: "X-Hermes-Session-Key")

        struct Body: Encodable { let input: HermesChatInput }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        request.httpBody = try encoder.encode(Body(input: input))

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HermesError.invalidResponse
        }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw HermesError.unauthorized
        case 404: throw HermesError.notFound
        default: throw HermesError.httpStatus(http.statusCode, nil)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var accumulator = SSEAccumulator()

        func handle(line: String) {
            guard let (eventName, dataStr) = accumulator.consume(line: line) else { return }
            guard dataStr != "[DONE]", let data = dataStr.data(using: .utf8) else { return }
            let event = parseEvent(name: eventName ?? "", data: data, decoder: decoder)
            continuation.yield(event)
        }

        // NOTE: We split on newlines manually rather than using `bytes.lines`.
        // Foundation's `AsyncLineSequence` discards empty lines, but those blank
        // lines are exactly the SSE event delimiters — dropping them means events
        // are never dispatched. Manual splitting preserves them.
        var buffer: [UInt8] = []
        for try await byte in bytes {
            try Task.checkCancellation()
            guard byte == 0x0A else {  // not '\n'
                buffer.append(byte)
                continue
            }
            handle(line: decodeLine(&buffer))
        }
        if !buffer.isEmpty {
            handle(line: decodeLine(&buffer))
        }
        // Flush a trailing event that wasn't terminated by a blank line.
        handle(line: "")
    }

    /// Decodes the accumulated bytes as a UTF-8 line, dropping a trailing `\r`
    /// (CRLF tolerance), and clears the buffer.
    private static func decodeLine(_ buffer: inout [UInt8]) -> String {
        var line = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: true)
        if line.hasSuffix("\r") { line.removeLast() }
        return line
    }

    private static func parseEvent(name: String, data: Data, decoder: JSONDecoder) -> HermesStreamEvent {
        switch name {
        case "run.started":
            if let payload = try? decoder.decode(RunStartedPayload.self, from: data) {
                return .runStarted(runID: payload.runId)
            }
        case "message.started":
            if let payload = try? decoder.decode(MessageStartedPayload.self, from: data) {
                return .messageStarted(messageID: payload.message?.id ?? payload.messageId ?? "")
            }
        case "assistant.delta":
            if let payload = try? decoder.decode(AssistantDeltaPayload.self, from: data) {
                return .assistantDelta(messageID: payload.messageId, text: payload.delta)
            }
        case "assistant.completed":
            if let payload = try? decoder.decode(AssistantCompletedPayload.self, from: data) {
                return .assistantCompleted(
                    messageID: payload.resolvedMessageID,
                    content: payload.resolvedContent,
                    reasoning: payload.resolvedReasoning
                )
            }
        case "tool.started":
            if let payload = try? decoder.decode(ToolStartedPayload.self, from: data) {
                let argsJSON = payload.args.flatMap { args -> String? in
                    guard let d = try? JSONSerialization.data(withJSONObject: args, options: .sortedKeys) else { return nil }
                    return String(data: d, encoding: .utf8)
                }
                return .toolStarted(messageID: payload.messageId, name: payload.toolName, arguments: argsJSON ?? payload.preview)
            }
        case "tool.completed":
            if let payload = try? decoder.decode(ToolCompletedPayload.self, from: data) {
                return .toolCompleted(messageID: payload.messageId, name: payload.toolName)
            }
        case "tool.progress", "hermes.tool.progress":
            if let payload = try? decoder.decode(ToolProgressPayload.self, from: data) {
                if payload.toolName == "_thinking" {
                    return .thinkingDelta(messageID: payload.messageId, text: payload.delta ?? "")
                }
                return .toolProgress(messageID: payload.messageId, name: payload.toolName, text: payload.delta ?? "")
            }
        case "done":
            return .unknown(event: name)
        case "run.completed":
            if let payload = try? decoder.decode(RunCompletedPayload.self, from: data) {
                return .runCompleted(messages: payload.messages ?? [], usage: payload.usage)
            }
        case "run.failed", "run.error":
            if let payload = try? decoder.decode(RunFailedPayload.self, from: data) {
                return .runFailed(error: payload.error ?? payload.message ?? "Unknown error")
            }
        default:
            // Check for approval events
            if name.contains("approval") {
                if let payload = try? decoder.decode(ApprovalPayload.self, from: data),
                   let runID = payload.runId,
                   let approvalID = payload.approvalId {
                    return .approvalRequired(runID: runID, approvalID: approvalID, prompt: payload.prompt ?? "")
                }
            }
        }
        log.debug("Unknown SSE event: \(name, privacy: .public)")
        return .unknown(event: name)
    }
}

// MARK: - Private payload types

private struct RunStartedPayload: Decodable {
    let runId: String
}

private struct MessageStartedPayload: Decodable {
    struct MessageStub: Decodable { let id: String }
    let message: MessageStub?
    let messageId: String?
}

private struct AssistantDeltaPayload: Decodable {
    let messageId: String
    let delta: String
}

private struct AssistantCompletedPayload: Decodable {
    struct Message: Decodable {
        let id: String?
        let content: String?
        let reasoning: String?
        let reasoningContent: String?
    }

    let messageId: String?
    let content: String?
    let reasoning: String?
    let reasoningContent: String?
    let message: Message?

    var resolvedMessageID: String {
        messageId ?? message?.id ?? ""
    }

    var resolvedContent: String {
        content ?? message?.content ?? ""
    }

    var resolvedReasoning: String? {
        reasoning ?? reasoningContent ?? message?.reasoning ?? message?.reasoningContent
    }
}

private struct ToolStartedPayload: Decodable {
    let messageId: String
    let toolName: String
    let preview: String?
    let args: [String: Any]?

    enum CodingKeys: String, CodingKey {
        case messageId, toolName, preview, args
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        messageId = try c.decode(String.self, forKey: .messageId)
        toolName = try c.decode(String.self, forKey: .toolName)
        preview = try c.decodeIfPresent(String.self, forKey: .preview)
        if let raw = try? c.decode(AnyCodable.self, forKey: .args) {
            args = raw.dictionaryValue
        } else {
            args = nil
        }
    }
}

private struct ToolCompletedPayload: Decodable {
    let messageId: String
    let toolName: String?
}

private struct ToolProgressPayload: Decodable {
    let messageId: String
    let toolName: String
    let delta: String?
}

private struct RunCompletedPayload: Decodable {
    let messages: [HermesMessage]?
    let usage: TokenUsage?
}

private struct RunFailedPayload: Decodable {
    let error: String?
    let message: String?
}

private struct ApprovalPayload: Decodable {
    let runId: String?
    let approvalId: String?
    let prompt: String?
}
