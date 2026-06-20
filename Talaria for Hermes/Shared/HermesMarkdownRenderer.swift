import Foundation

nonisolated enum HermesMarkdownRenderer {
    static func prepare(_ source: String) -> String {
        let normalized = source.hasPrefix("\u{feff}") ? String(source.dropFirst()) : source
        return closingUnfinishedFence(in: renderingTaskMarkers(in: normalized))
    }

    private static func renderingTaskMarkers(in source: String) -> String {
        var isInsideFence = false
        var renderedLines: [String] = []
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)

        for line in lines {
            let string = String(line)
            if fenceMarker(in: string) != nil {
                isInsideFence.toggle()
                renderedLines.append(string)
            } else if isInsideFence {
                renderedLines.append(string)
            } else {
                renderedLines.append(renderedTaskLine(from: string) ?? string)
            }
        }

        return renderedLines.joined(separator: "\n")
    }

    private static func renderedTaskLine(from line: String) -> String? {
        let leadingWhitespace = line.prefix { $0 == " " || $0 == "\t" }
        let rest = Array(line.dropFirst(leadingWhitespace.count))
        guard rest.count >= 6,
              rest[1] == " ",
              rest[2] == "[",
              rest[4] == "]",
              rest[5] == " ",
              rest[0] == "-" || rest[0] == "*"
        else { return nil }

        let checkmark: String
        switch rest[3] {
        case "x", "X":
            checkmark = "☑︎"
        case " ":
            checkmark = "☐"
        default:
            return nil
        }

        return "\(leadingWhitespace)\(rest[0]) \(checkmark) \(String(rest.dropFirst(6)))"
    }

    private static func closingUnfinishedFence(in source: String) -> String {
        var activeFence: String?
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)

        for line in lines {
            guard let marker = fenceMarker(in: String(line)) else { continue }
            if activeFence == nil {
                activeFence = marker
            } else if activeFence == marker {
                activeFence = nil
            }
        }

        guard let activeFence else { return source }
        return source.hasSuffix("\n") ? source + activeFence : source + "\n" + activeFence
    }

    private static func fenceMarker(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") { return "```" }
        if trimmed.hasPrefix("~~~") { return "~~~" }
        return nil
    }
}
