import Foundation

enum ToolCallFormatting {
    static func displayName(_ name: String) -> String {
        let parts = name.components(separatedBy: "_")
        if parts.count > 2 && parts.first == "mcp" {
            return parts.dropFirst(2).joined(separator: "_")
        }
        return name
    }

    static func cleanOutput(_ raw: String) -> String {
        var text = raw
        if let start = text.range(of: "<untrusted_tool_result"),
           let end = text.range(of: ">", range: start.upperBound..<text.endIndex) {
            text = String(text[end.upperBound...])
        }
        if text.hasSuffix("</untrusted_tool_result>") {
            text = String(text.dropLast("</untrusted_tool_result>".count))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func summary(for entry: ChatTurn.ToolEntry) -> String {
        if let arguments = entry.arguments,
           let summary = argumentSummary(from: arguments) {
            return summary
        }
        if let progress = entry.progress,
           let summary = firstUsefulLine(in: progress) {
            return summary
        }
        if let output = entry.output,
           let summary = firstUsefulLine(in: cleanOutput(output)) {
            return summary
        }
        return displayName(entry.name)
    }

    private static let priorityKeys = [
        "command", "cmd", "path", "file_path", "filepath", "file", "paths",
        "pattern", "query", "q", "url", "content", "text", "old_string",
        "new_string", "line", "offset", "limit", "name", "args"
    ]

    private static func argumentSummary(from raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else {
            return firstUsefulLine(in: raw)
        }

        if let dictionary = object as? [String: Any] {
            for key in priorityKeys {
                guard let value = dictionary[key],
                      let string = normalizedString(from: value)
                else { continue }
                return string
            }

            for key in dictionary.keys.sorted() {
                guard let string = normalizedString(from: dictionary[key] ?? NSNull()) else { continue }
                return "\(key): \(string)"
            }

            return nil
        }

        return normalizedString(from: object)
    }

    private static func normalizedString(from value: Any) -> String? {
        switch value {
        case let string as String:
            return string.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        case let number as NSNumber:
            return number.stringValue
        case is NSNull:
            return nil
        default:
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                  let string = String(data: data, encoding: .utf8)
            else { return nil }
            return string.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        }
    }

    private static func firstUsefulLine(in text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
