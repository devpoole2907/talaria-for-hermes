import Foundation

/// Accumulates SSE lines and emits (eventName, data) pairs on blank-line boundaries.
struct SSEAccumulator: Sendable {
    private var dataLines: [String] = []
    private var eventName: String?

    mutating func consume(line: String) -> (eventName: String?, data: String)? {
        if line.isEmpty {
            defer {
                dataLines.removeAll()
                eventName = nil
            }
            guard !dataLines.isEmpty else { return nil }
            return (eventName, dataLines.joined(separator: "\n"))
        }

        // Comment line
        if line.hasPrefix(":") { return nil }

        if let colonIdx = line.firstIndex(of: ":") {
            let field = String(line[..<colonIdx])
            var value = String(line[line.index(after: colonIdx)...])
            if value.first == " " { value.removeFirst() }
            switch field {
            case "data":  dataLines.append(value)
            case "event": eventName = value
            default:      break
            }
        }
        return nil
    }
}
