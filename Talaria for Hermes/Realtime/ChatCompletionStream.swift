import Foundation
import OSLog

enum ChatCompletionStream {
    private static let log = Logger(subsystem: "ai.talaria.client.ios", category: "ChatCompletionStream")

    static func make(
        baseURL: URL,
        apiKey: String,
        messages: [HermesMessage],
        model: String
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await pump(
                        baseURL: baseURL,
                        apiKey: apiKey,
                        messages: messages,
                        model: model,
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
        messages: [HermesMessage],
        model: String,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = .infinity
        let session = URLSession(configuration: config)

        let url = baseURL.appending(path: "/v1/chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let chatMessages = messages.compactMap { msg -> [String: String]? in
            guard msg.role == "user" || msg.role == "assistant", let content = msg.content, !content.isEmpty else { return nil }
            return ["role": msg.role, "content": content]
        }

        struct Body: Encodable {
            let model: String
            let stream: Bool
            let messages: [[String: String]]
        }
        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(Body(model: model, stream: true, messages: chatMessages))

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw HermesError.invalidResponse }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw HermesError.unauthorized
        default: throw HermesError.httpStatus(http.statusCode, nil)
        }

        let decoder = JSONDecoder()
        var accumulator = SSEAccumulator()
        var stop = false

        func handle(line: String) {
            guard !stop, let (_, dataStr) = accumulator.consume(line: line) else { return }
            if dataStr == "[DONE]" { stop = true; return }
            guard let data = dataStr.data(using: .utf8) else { return }
            if let chunk = try? decoder.decode(ChatCompletionChunk.self, from: data),
               let content = chunk.choices.first?.delta.content, !content.isEmpty {
                continuation.yield(content)
            }
        }

        // Split on newlines manually: `bytes.lines` drops the empty lines that
        // delimit SSE events, so events would never be dispatched.
        var buffer: [UInt8] = []
        for try await byte in bytes {
            try Task.checkCancellation()
            if stop { break }
            guard byte == 0x0A else {  // not '\n'
                buffer.append(byte)
                continue
            }
            handle(line: decodeLine(&buffer))
        }
        if !stop, !buffer.isEmpty {
            handle(line: decodeLine(&buffer))
        }
        if !stop { handle(line: "") }
    }

    private static func decodeLine(_ buffer: inout [UInt8]) -> String {
        var line = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: true)
        if line.hasSuffix("\r") { line.removeLast() }
        return line
    }
}

private struct ChatCompletionChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable { let content: String? }
        let delta: Delta
    }
    let choices: [Choice]
}
