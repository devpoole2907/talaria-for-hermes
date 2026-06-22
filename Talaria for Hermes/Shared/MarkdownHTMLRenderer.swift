import Foundation

/// Markdown → HTML for the WebView timeline. Reuses `HermesMarkdownRenderer.prepare`
/// (task markers, unclosed fences) so there's a single markdown pipeline, then walks
/// the prepared source block-by-block.
///
/// Supports: ATX headings, paragraphs, fenced code, inline code, bold, italic,
/// strikethrough, links, images, nested ordered/unordered lists, GFM tables,
/// blockquotes, and horizontal rules. Not a full CommonMark implementation, but
/// covers the constructs LLM output uses in practice.
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

            if isHorizontalRule(trimmed) {
                flushParagraph()
                out.append("<hr>")
                i += 1
                continue
            }

            if let h = heading(trimmed) {
                flushParagraph()
                out.append(h)
                i += 1
                continue
            }

            // GFM table: a row containing "|" immediately followed by a delimiter row.
            if trimmed.contains("|"), i + 1 < lines.count,
               isTableDelimiter(lines[i + 1].trimmingCharacters(in: .whitespaces)) {
                flushParagraph()
                let (tableHTML, next) = parseTable(lines, headerIndex: i)
                out.append(tableHTML)
                i = next
                continue
            }

            if isListItem(line) != nil {
                flushParagraph()
                let (listHTML, next) = parseList(lines: lines, start: i)
                out.append(listHTML)
                i = next
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

    // MARK: - Headings / rules

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

    private static func isHorizontalRule(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: " ", with: "")
        guard stripped.count >= 3 else { return false }
        return stripped.allSatisfy { $0 == "-" } || stripped.allSatisfy { $0 == "*" } || stripped.allSatisfy { $0 == "_" }
    }

    // MARK: - Lists (nested)

    /// Indentation (in spaces, tab = 4) and ordered-ness of a list item, or nil.
    private static func isListItem(_ line: String) -> (indent: Int, ordered: Bool, content: String)? {
        var indent = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == " " || line[idx] == "\t" {
            indent += line[idx] == "\t" ? 4 : 1
            idx = line.index(after: idx)
        }
        let rest = String(line[idx...])
        if rest.hasPrefix("- ") || rest.hasPrefix("* ") || rest.hasPrefix("+ ") {
            return (indent, false, String(rest.dropFirst(2)))
        }
        // Ordered: digits + "." + space
        var digits = 0
        for ch in rest {
            if ch.isNumber { digits += 1 } else { break }
        }
        if digits > 0 {
            let after = rest.dropFirst(digits)
            if after.first == ".", after.dropFirst().first == " " {
                return (indent, true, String(after.dropFirst(2)))
            }
        }
        return nil
    }

    private static func parseList(lines: [String], start: Int) -> (String, Int) {
        var items: [(indent: Int, ordered: Bool, content: String)] = []
        var i = start
        while i < lines.count, let item = isListItem(lines[i]) {
            items.append(item)
            i += 1
        }

        var html = ""
        var stack: [(indent: Int, ordered: Bool)] = []
        var liOpenAt: [Bool] = []  // parallels stack: is an <li> currently open at this level

        func openList(_ ordered: Bool, indent: Int) {
            html += ordered ? "<ol>" : "<ul>"
            stack.append((indent, ordered))
            liOpenAt.append(false)
        }
        func closeList() {
            if liOpenAt.last == true { html += "</li>" }
            html += stack.last!.ordered ? "</ol>" : "</ul>"
            stack.removeLast()
            liOpenAt.removeLast()
        }

        for item in items {
            if stack.isEmpty {
                openList(item.ordered, indent: item.indent)
            } else if item.indent > stack.last!.indent {
                // Child list nested inside the current (still-open) <li>.
                openList(item.ordered, indent: item.indent)
            } else {
                // Close deeper levels until we reach this item's level.
                while stack.count > 1, item.indent < stack.last!.indent {
                    closeList()
                }
                // Close the open <li> at this level before starting a sibling.
                if liOpenAt.last == true { html += "</li>"; liOpenAt[liOpenAt.count - 1] = false }
                // Switch list type at the same level if it changed.
                if item.ordered != stack.last!.ordered {
                    closeList()
                    openList(item.ordered, indent: item.indent)
                }
            }
            html += "<li>\(inline(item.content))"
            liOpenAt[liOpenAt.count - 1] = true
        }
        while !stack.isEmpty { closeList() }
        return (html, i)
    }

    // MARK: - Tables (GFM)

    private static func isTableDelimiter(_ line: String) -> Bool {
        guard line.contains("-") else { return false }
        let cells = splitRow(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let c = cell.trimmingCharacters(in: .whitespaces)
            guard !c.isEmpty else { return false }
            return c.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func parseTable(_ lines: [String], headerIndex: Int) -> (String, Int) {
        let header = splitRow(lines[headerIndex].trimmingCharacters(in: .whitespaces))
        let aligns = splitRow(lines[headerIndex + 1].trimmingCharacters(in: .whitespaces)).map { cell -> String in
            let c = cell.trimmingCharacters(in: .whitespaces)
            let left = c.hasPrefix(":"), right = c.hasSuffix(":")
            if left && right { return "center" }
            if right { return "right" }
            if left { return "left" }
            return ""
        }

        func align(_ i: Int) -> String {
            guard i < aligns.count, !aligns[i].isEmpty else { return "" }
            return " style=\"text-align:\(aligns[i])\""
        }

        var html = "<table><thead><tr>"
        for (i, cell) in header.enumerated() {
            html += "<th\(align(i))>\(inline(cell.trimmingCharacters(in: .whitespaces)))</th>"
        }
        html += "</tr></thead><tbody>"

        var i = headerIndex + 2
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            guard t.contains("|"), !t.isEmpty else { break }
            let cells = splitRow(t)
            html += "<tr>"
            for col in 0..<header.count {
                let value = col < cells.count ? cells[col].trimmingCharacters(in: .whitespaces) : ""
                html += "<td\(align(col))>\(inline(value))</td>"
            }
            html += "</tr>"
            i += 1
        }
        html += "</tbody></table>"
        return (html, i)
    }

    /// Splits a table row on unescaped pipes, dropping the optional leading/trailing
    /// empty cells produced by outer `|`.
    private static func splitRow(_ row: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaped = false
        for ch in row {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" { current.append(ch); escaped = true; continue }
            if ch == "|" { cells.append(current); current = ""; continue }
            current.append(ch)
        }
        cells.append(current)
        if cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeFirst() }
        if cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeLast() }
        return cells
    }

    // MARK: - Inline

    private static func inline(_ text: String) -> String {
        var s = escape(text)
        s = regexReplace(s, "`([^`]+)`", "<code>$1</code>")
        s = regexReplace(s, "!\\[([^\\]]*)\\]\\(([^)\\s]+)\\)", "<img alt=\"$1\" src=\"$2\">")
        s = regexReplace(s, "\\[([^\\]]+)\\]\\(([^)\\s]+)\\)", "<a href=\"$2\">$1</a>")
        s = regexReplace(s, "\\*\\*([^*]+)\\*\\*", "<strong>$1</strong>")
        s = regexReplace(s, "__([^_]+)__", "<strong>$1</strong>")
        s = regexReplace(s, "~~([^~]+)~~", "<del>$1</del>")
        s = regexReplace(s, "(?<!\\*)\\*([^*]+)\\*(?!\\*)", "<em>$1</em>")
        s = regexReplace(s, "(?<![A-Za-z0-9_])_([^_]+)_(?![A-Za-z0-9_])", "<em>$1</em>")
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
