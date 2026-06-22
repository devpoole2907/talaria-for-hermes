import Foundation
import OSLog

/// SSE streaming for the Hermes Runs API (/v1/runs/{id}/events).
///
/// Unlike the session-stream path, events here carry the event name inside the
/// JSON data field ("event": "<name>") rather than the SSE `event:` field. The
/// stream stays open across tool calls and approval pauses — reconnect when
/// the server drops the connection (e.g. after an approval is posted).
enum RunEventStream {
    private static let log = Logger(subsystem: "ai.talaria.client.ios", category: "RunEventStream")

    /// Streams events from an already-created run.
    static func events(
        baseURL: URL,
        apiKey: String,
        runID: String
    ) -> AsyncThrowingStream<HermesStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await pump(
                        baseURL: baseURL,
                        apiKey: apiKey,
                        runID: runID,
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
        runID: String,
        continuation: AsyncThrowingStream<HermesStreamEvent, Error>.Continuation
    ) async throws {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = .infinity
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)

        let url = baseURL.appending(path: "/v1/runs/\(runID)/events")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HermesError.invalidResponse
        }
        switch http.statusCode {
        case 200..<300:
            break
        case 404:
            throw HermesError.notFound
        case 401, 403:
            throw HermesError.unauthorized
        default:
            let body = await collectErrorBody(bytes)
            throw HermesError.httpStatus(http.statusCode, body.isEmpty ? nil : body)
        }

        let decoder = JSONDecoder()
        // Runs API uses snake_case in event JSON.
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        // Manual newline splitting — same reason as HermesEventStream:
        // AsyncLineSequence drops empty lines, which are the SSE delimiters.
        var buffer: [UInt8] = []

        func handleLine(_ line: String) {
            // Runs API: each non-empty data line is a complete JSON object.
            // We don't use SSEAccumulator here because there's no SSE `event:` field.
            guard line.hasPrefix("data: ") else { return }
            let json = String(line.dropFirst(6)) // drop "data: "
            guard json != "[DONE]", let data = json.data(using: .utf8) else { return }
            let event = parseRunEvent(data: data, decoder: decoder)
            continuation.yield(event)
        }

        for try await byte in bytes {
            try Task.checkCancellation()
            guard byte == 0x0A else {
                buffer.append(byte)
                continue
            }
            var line = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll(keepingCapacity: true)
            if line.hasSuffix("\r") { line.removeLast() }
            handleLine(line)
        }
        if !buffer.isEmpty {
            var line = String(decoding: buffer, as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }
            handleLine(line)
        }
    }

    private static func collectErrorBody(_ bytes: URLSession.AsyncBytes) async -> String {
        var data: [UInt8] = []
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= 8192 { break }
            }
        } catch {}
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Event parsing

    private static func parseRunEvent(data: Data, decoder: JSONDecoder) -> HermesStreamEvent {
        // All Runs API events carry "event" in the JSON body.
        guard let envelope = try? decoder.decode(RunEventEnvelope.self, from: data) else {
            log.debug("Runs API: unparseable event data")
            return .unknown(event: "")
        }

        let name = envelope.event
        log.debug("Runs API event: \(name, privacy: .public)")

        switch name {
        case "message.delta":
            if let p = try? decoder.decode(RunMessageDeltaPayload.self, from: data) {
                // Runs API has no per-message id; use the run_id as a stable key.
                return .assistantDelta(messageID: p.runId, text: p.delta)
            }

        case "reasoning.available":
            if let p = try? decoder.decode(RunReasoningPayload.self, from: data) {
                return .thinkingDelta(messageID: p.runId, text: p.text)
            }

        case "tool.started":
            // Runs API uses "tool" not "tool_name", and has no "messageId".
            if let p = try? decoder.decode(RunToolStartedPayload.self, from: data) {
                return .toolStarted(messageID: p.runId, name: p.tool, arguments: p.preview)
            }

        case "tool.completed":
            if let p = try? decoder.decode(RunToolCompletedPayload.self, from: data) {
                return .toolCompleted(messageID: p.runId, name: p.tool)
            }

        case "tool.progress":
            if let p = try? decoder.decode(RunToolProgressPayload.self, from: data) {
                return .toolProgress(messageID: p.runId, name: p.tool ?? "terminal", text: p.delta ?? "")
            }

        case "approval.request":
            if let p = try? decoder.decode(RunApprovalRequestPayload.self, from: data) {
                let req = ApprovalRequest(
                    runID: p.runId,
                    command: p.command ?? p.description ?? "",
                    description: p.description ?? p.command ?? "",
                    choices: p.choices ?? ["once", "session", "deny"],
                    allowPermanent: p.allowPermanent ?? false,
                    patternKey: p.patternKey
                )
                return .runsApprovalRequired(req)
            }

        case "run.completed":
            if let p = try? decoder.decode(RunCompletedPayload.self, from: data) {
                // Runs API run.completed does NOT include messages — client fetches
                // /api/sessions/{id}/messages for the authoritative final transcript.
                // Pass an empty messages array; ChatStore handles the fetch.
                return .runCompleted(messages: [], usage: p.usage)
            }

        case "run.failed", "run.error":
            if let p = try? decoder.decode(RunFailedPayload.self, from: data) {
                return .runFailed(error: p.error ?? p.message ?? "Run failed")
            }

        default:
            break
        }

        return .unknown(event: name)
    }
}

// MARK: - Payload types (private)

/// Minimal envelope to extract the event name from any Runs API event.
private struct RunEventEnvelope: Decodable {
    let event: String
}

private struct RunMessageDeltaPayload: Decodable {
    let runId: String
    let delta: String
}

private struct RunReasoningPayload: Decodable {
    let runId: String
    let text: String
}

private struct RunToolStartedPayload: Decodable {
    let runId: String
    let tool: String
    let preview: String?
}

private struct RunToolCompletedPayload: Decodable {
    let runId: String
    let tool: String?
    let duration: Double?
    let error: Bool?
}

private struct RunToolProgressPayload: Decodable {
    let runId: String
    let tool: String?
    let delta: String?
}

private struct RunApprovalRequestPayload: Decodable {
    let runId: String
    let command: String?
    let description: String?
    let choices: [String]?
    let allowPermanent: Bool?
    let patternKey: String?
    let patternKeys: [String]?
}

private struct RunCompletedPayload: Decodable {
    let runId: String
    let output: String?
    let usage: TokenUsage?
}

private struct RunFailedPayload: Decodable {
    let error: String?
    let message: String?
}
