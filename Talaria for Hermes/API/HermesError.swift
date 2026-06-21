import Foundation

enum HermesError: Error, LocalizedError, Equatable, Sendable {
    case httpStatus(Int, String?)
    case decoding(String)
    case network(String)
    case unauthorized
    case notFound
    case rateLimited
    case cancelled
    case invalidURL
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code, let body):
            if let body, !body.isEmpty {
                "Server returned HTTP \(code): \(body)"
            } else {
                "Server returned HTTP \(code)."
            }
        case .decoding(let detail):
            "Couldn't decode the server response. \(detail)"
        case .network(let detail):
            "Network error: \(detail)"
        case .unauthorized:
            "The server credentials are incorrect or missing."
        case .notFound:
            "The requested resource was not found."
        case .rateLimited:
            "The server is rate-limiting requests. Try again in a moment."
        case .cancelled:
            "The request was cancelled."
        case .invalidURL:
            "The server URL is not valid."
        case .invalidResponse:
            "The server response was not understood."
        }
    }

    /// A server-provided failure message worth showing inline in the chat timeline
    /// (model/agent rejections that came back with a body), or nil when the failure
    /// is a transport/auth problem better surfaced as a connection alert.
    var inlineChatMessage: String? {
        switch self {
        case .httpStatus(_, let body):
            guard let body, !body.isEmpty else { return nil }
            return body
        default:
            return nil
        }
    }

    init(_ underlying: Error) {
        if let mapped = underlying as? HermesError {
            self = mapped
            return
        }
        if Task.isCancelled || (underlying as NSError).code == NSURLErrorCancelled {
            self = .cancelled
            return
        }
        if let decodingError = underlying as? DecodingError {
            self = .decoding(String(describing: decodingError))
            return
        }
        self = .network(underlying.localizedDescription)
    }
}
