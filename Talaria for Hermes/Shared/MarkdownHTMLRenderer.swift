import Foundation

/// Compact Markdown → HTML converter for the WebView timeline. Reuses
/// `HermesMarkdownRenderer.prepare` (task markers, unclosed fences) so there's a
/// single markdown pipeline, then walks the prepared source block-by-block.
///
/// Phase 1 scope: headings, paragraphs, fenced code, inline code, bold, italic,
/// links, unordered/ordered lists, blockquotes — enough to evaluate scrolling and
/// look right for typical chat content. Not a full CommonMark implementation.
nonisolated enum MarkdownHTMLRenderer {
    static func html(from markdown: String) -> String {
        let prepared = HermesMarkdownRenderer.prepare(markdown)
        let lines = prepared.components(separatedBy: "\n")
        var out: [String] = []
        var paragraph: [String] = []
        var i = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            out.append("<p>\(inline(paragraph.joined(separator: " ")))</p>")
            paragraph.removeAll()
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                var code: [String] = []
                i += 1
                while i < lines.count {
                    if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { break }
                    code.append(lines[i])
                    i += 1
                }
                out.append("<pre><code>\(escape(code.joined(separator: "\n")))</code></pre>")
                i += 1
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            if let h = heading(trimmed) {
                flushParagraph()
                out.append(h)
                i += 1
                continue
            }

            if isUnordered(trimmed) {
                flushParagraph()
                var items: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard isUnordered(t) else { break }
                    items.append("<li>\(inline(String(t.dropFirst(2))))</li>")
                    i += 1
                }
                out.append("<ul>\(items.joined())</ul>")
                continue
            }

            if let dropCount = orderedPrefixLength(trimmed) {
                flushParagraph()
                var items: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard let n = orderedPrefixLength(t) else { break }
                    items.append("<li>\(inline(String(t.dropFirst(n))))</li>")
                    i += 1
                }
                _ = dropCount
                out.append("<ol>\(items.joined())</ol>")
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quote: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    quote.append(inline(String(t.dropFirst(1)).trimmingCharacters(in: .whitespaces)))
                    i += 1
                }
                out.append("<blockquote>\(quote.joined(separator: "<br>"))</blockquote>")
                continue
            }

            paragraph.append(trimmed)
            i += 1
        }
        flushParagraph()
        return out.joined()
    }

    // MARK: - Blocks

    private static func heading(_ line: String) -> String? {
        var level = 0
        for ch in line {
            if ch == "#" { level += 1 } else { break }
        }
        guard level >= 1, level <= 6 else { return nil }
        let rest = line.dropFirst(level)
        guard rest.first == " " else { return nil }
        return "<h\(level)>\(inline(rest.trimmingCharacters(in: .whitespaces)))</h\(level)>"
    }

    private static func isUnordered(_ line: String) -> Bool {
        line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
    }

    /// Length of an ordered-list marker (`12. `) to drop, or nil.
    private static func orderedPrefixLength(_ line: String) -> Int? {
        var digits = 0
        for ch in line {
            if ch.isNumber { digits += 1 } else { break }
        }
        guard digits > 0 else { return nil }
        let after = line.dropFirst(digits)
        guard after.first == ".", after.dropFirst().first == " " else { return nil }
        return digits + 2
    }

    // MARK: - Inline

    private static func inline(_ text: String) -> String {
        var s = escape(text)
        s = regexReplace(s, "`([^`]+)`", "<code>$1</code>")
        s = regexReplace(s, "\\*\\*([^*]+)\\*\\*", "<strong>$1</strong>")
        s = regexReplace(s, "__([^_]+)__", "<strong>$1</strong>")
        s = regexReplace(s, "(?<!\\*)\\*([^*]+)\\*(?!\\*)", "<em>$1</em>")
        s = regexReplace(s, "(?<!_)_([^_]+)_(?!_)", "<em>$1</em>")
        s = regexReplace(s, "\\[([^\\]]+)\\]\\(([^)\\s]+)\\)", "<a href=\"$2\">$1</a>")
        return s
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func regexReplace(_ s: String, _ pattern: String, _ template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: template)
    }
}
