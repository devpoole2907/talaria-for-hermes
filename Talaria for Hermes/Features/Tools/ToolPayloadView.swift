import SwiftUI

/// A titled section inside an expanded tool call (e.g. "Input", "Output").
struct ToolPayloadSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .bold()
                .foregroundStyle(.secondary)
            content
        }
    }
}

/// Renders a tool payload string: a JSON object becomes labeled key/value rows,
/// a JSON array/scalar becomes pretty-printed, and anything else (e.g. command
/// output) is shown as a plain monospaced block.
struct ToolPayloadBody: View {
    let raw: String

    var body: some View {
        if let fields = ToolJSON.fields(from: raw), !fields.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.s) {
                ForEach(fields) { ToolFieldRow(field: $0) }
            }
        } else if let pretty = ToolJSON.prettyNonObject(from: raw) {
            ToolValueBlock(text: pretty)
        } else {
            ToolValueBlock(text: raw)
        }
    }
}

/// A single key/value row from a tool's JSON input.
private struct ToolFieldRow: View {
    let field: ToolJSON.Field

    var body: some View {
        switch field.value {
        case .inline(let value):
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Text(field.key)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .block(let value):
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(field.key)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ToolValueBlock(text: value)
            }
        }
    }
}

/// A monospaced value block with a subtle background and "Show more" for long content.
struct ToolValueBlock: View {
    let text: String
    var collapsedLineLimit: Int = 12

    @State private var showFull = false

    private var isTruncatable: Bool {
        text.split(separator: "\n", omittingEmptySubsequences: false).count > collapsedLineLimit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(showFull ? nil : collapsedLineLimit)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Spacing.s)
                .padding(.horizontal, Spacing.m)
                .background(.primary.opacity(0.05), in: .rect(cornerRadius: Radii.small))

            if isTruncatable {
                Button(showFull ? "Show less" : "Show more") {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        showFull.toggle()
                    }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }
        }
    }
}

// MARK: - JSON parsing

enum ToolJSON {
    enum Value {
        case inline(String)  // short scalar — render beside its key
        case block(String)   // multiline/long string or nested JSON — render below its key
    }

    struct Field: Identifiable {
        let key: String
        let value: Value
        var id: String { key }
    }

    /// Top-level keys for common tools, surfaced first; everything else falls back to alphabetical.
    private static let keyPriority = [
        "command", "cmd", "path", "file_path", "filepath", "file", "paths",
        "pattern", "query", "q", "url", "content", "text", "old_string",
        "new_string", "line", "offset", "limit", "name", "args"
    ]

    static func fields(from raw: String) -> [Field]? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any]
        else { return nil }

        return orderedKeys(of: object).map { key in
            Field(key: key, value: value(for: object[key] ?? NSNull()))
        }
    }

    static func prettyNonObject(from raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              !(any is [String: Any])
        else { return nil }

        guard let pretty = try? JSONSerialization.data(withJSONObject: any, options: [.prettyPrinted]),
              let string = String(data: pretty, encoding: .utf8)
        else { return nil }
        return string
    }

    private static func orderedKeys(of object: [String: Any]) -> [String] {
        object.keys.sorted { lhs, rhs in
            let li = keyPriority.firstIndex(of: lhs) ?? Int.max
            let ri = keyPriority.firstIndex(of: rhs) ?? Int.max
            return li == ri ? lhs < rhs : li < ri
        }
    }

    private static func value(for any: Any) -> Value {
        switch any {
        case let string as String:
            return (string.contains("\n") || string.count > 60) ? .block(string) : .inline(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .inline(number.boolValue ? "true" : "false")
            }
            return .inline(number.stringValue)
        case is NSNull:
            return .inline("null")
        default:
            if let pretty = try? JSONSerialization.data(withJSONObject: any, options: [.prettyPrinted, .sortedKeys]),
               let string = String(data: pretty, encoding: .utf8) {
                return .block(string)
            }
            return .block("\(any)")
        }
    }
}
