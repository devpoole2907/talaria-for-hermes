import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Chat timeline rendered in a native iOS 26 `WebView`. The browser engine lays out
/// the entire conversation and owns scrolling, so variable-height messages never
/// trigger the estimate-then-correct offset jumps that plague `LazyVStack` /
/// `UICollectionView`. Turns are converted to HTML (markdown via
/// `MarkdownHTMLRenderer`) and pushed into the page; appends/streaming updates mutate
/// the DOM incrementally via `callJavaScript`, so scroll position is preserved.
///
/// Styling mirrors the app's native chat bubbles closely enough to be
/// indistinguishable. This is the sole timeline implementation (earlier
/// SwiftUI/UICollectionView attempts were removed once the WebView won on scrolling).
struct MessageTimelineWebView: View {
    let store: ChatStore
    var bottomPadding: CGFloat = 0
    var onDropFiles: ([URL]) -> Void = { _ in }
    var onDropImageData: (Data) -> Void = { _ in }

    @State private var page = WebPage()
    @State private var isDragOver = false
    @State private var renderedIDs: [String] = []
    @State private var lastTurnSignature = ""
    @State private var didLoad = false
    // Re-entrancy guard: several .onChange handlers can fire for one send, and sync()
    // suspends at `await runJS`. Without serialization they interleave and read stale
    // `renderedIDs`, double-appending the just-sent turn. Coalesce instead.
    @State private var isSyncing = false
    @State private var needsResync = false

    var body: some View {
        Group {
            if store.loading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.turns.isEmpty && !store.working {
                WebTimelineEmptyState()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                WebView(page)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    #if canImport(UIKit)
                    // The SwiftUI WebView owns its own scroll view, which
                    // `.scrollDismissesKeyboard` can't reach — so the swipe-to-dismiss
                    // gesture stopped working when the timeline became a WebView. Reach
                    // the underlying WKWebView's scroll view and restore it natively.
                    .background(WebKeyboardDismissConfigurator())
                    #endif
                    #if targetEnvironment(macCatalyst)
                    // WKWebView intercepts all drag sessions before SwiftUI .onDrop
                    // can see them, so we attach UIDropInteraction directly to the
                    // web view via the same UIView probe/walk used for keyboard dismiss.
                    .background(WebDropInteractionInstaller(
                        onDropFiles: onDropFiles,
                        onDropImageData: onDropImageData,
                        onDragActiveChanged: { isDragOver = $0 }
                    ))
                    .overlay { if isDragOver { DropTargetOverlay() } }
                    #endif
                    .task { await sync() }
                    .onChange(of: store.turns.count) { Task { await sync() } }
                    .onChange(of: store.streamingRevision) { Task { await sync() } }
                    .onChange(of: store.working) { Task { await sync() } }
                    .onChange(of: store.reconnecting) { Task { await sync() } }
            }
        }
        .background(.background)
    }

    // MARK: - Sync (Swift → page)

    /// Serialized entry point: only one sync runs at a time; changes arriving mid-sync
    /// request a follow-up pass that reads fresh state, so nothing double-applies.
    @MainActor
    private func sync() async {
        if isSyncing { needsResync = true; return }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            needsResync = false
            await syncOnce()
        } while needsResync
    }

    @MainActor
    private func syncOnce() async {
        let turns = store.turns
        guard !turns.isEmpty else { return }

        let ids = turns.map(\.id.uuidString)
        let lastSig = signature(for: turns.last, isLast: true)

        // First render: load the whole document with all turns inline. The page's
        // own load handler scrolls to the bottom and fades in.
        if !didLoad {
            page.load(html: document(turns: turns), baseURL: URL(string: "about:blank")!)
            renderedIDs = ids
            lastTurnSignature = lastSig
            didLoad = true
            return
        }

        // Pure append (send / reply landed): existing turns unchanged, new ones added.
        if ids.count > renderedIDs.count, Array(ids.prefix(renderedIDs.count)) == renderedIDs {
            let appended = turns.suffix(ids.count - renderedIDs.count).map { turnHTML($0, isLast: $0.id == turns.last?.id) }
            if let json = encode(appended) {
                await runJS("appendTurns(\(json));")
            }
            renderedIDs = ids
            lastTurnSignature = lastSig
            return
        }

        // Same structure: only the live (last) turn's content changed — streaming.
        if ids == renderedIDs {
            if lastSig != lastTurnSignature, let last = turns.last {
                if let json = encode(turnHTML(last, isLast: true)) {
                    await runJS("replaceLast(\(json));")
                }
                lastTurnSignature = lastSig
            }
            return
        }

        // Anything else (reconcile / reload / truncation): re-render wholesale.
        page.load(html: document(turns: turns), baseURL: URL(string: "about:blank")!)
        renderedIDs = ids
        lastTurnSignature = lastSig
    }

    /// callJavaScript can throw if invoked before the freshly-loaded page is ready;
    /// retry briefly so an append/stream right after load still lands.
    private func runJS(_ script: String) async {
        for _ in 0..<6 {
            do {
                _ = try await page.callJavaScript(script + "\nreturn null;")
                return
            } catch {
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
    }

    // MARK: - Turn → HTML

    private func signature(for turn: ChatTurn?, isLast: Bool) -> String {
        guard let turn else { return "" }
        var parts: [String] = [turn.userMessage.message.content ?? "", turn.isSending ? "S" : ""]
        for block in turn.blocks {
            switch block {
            case .text(_, let content, let streaming): parts.append("t:\(content):\(streaming)")
            case .tool(let e): parts.append("x:\(e.name):\(e.isRunning):\(e.arguments ?? ""):\(e.output ?? ""):\(e.progress ?? "")")
            }
        }
        parts.append(turn.assistantModelID ?? "")
        parts.append(reasoningText(turn) ?? "")
        if isLast { parts.append("w:\(store.working):\(store.reconnecting)") }
        return parts.joined(separator: "|")
    }

    /// Reasoning to show for a turn: the live stream while working, else the persisted
    /// reasoning from the turn's assistant messages (so reloading a chat keeps the
    /// reasoning section and a reasoning-only reply never renders blank).
    private func reasoningText(_ turn: ChatTurn) -> String? {
        if let live = turn.streamingThinking, !live.isEmpty { return live }
        for message in turn.assistantMessages {
            if let r = message.message.reasoning ?? message.message.reasoningContent, !r.isEmpty {
                return r
            }
        }
        return nil
    }

    private func turnHTML(_ turn: ChatTurn, isLast: Bool) -> String {
        var html = "<div class=\"turn\" id=\"turn-\(turn.id.uuidString)\">"
        html += userHTML(turn)
        html += assistantHTML(turn)
        html += indicatorHTML(turn, isLast: isLast)
        html += noResponseHTML(turn, isLast: isLast)
        html += "</div>"
        return html
    }

    /// A finalized user turn with no assistant reply (the run errored or never
    /// persisted a response — the inline error bubble is local-only and gone on
    /// reload). Make it explicit so a bare user message doesn't look like a bug.
    private func noResponseHTML(_ turn: ChatTurn, isLast: Bool) -> String {
        let isLive = isLast && (store.working || store.reconnecting)
        guard !isLive,
              turn.userMessage.message.content?.isEmpty == false,
              turn.blocks.isEmpty,
              reasoningText(turn) == nil
        else { return "" }
        return "<div class=\"no-response\">\(Self.warnSVG)<span>No response recorded for this message.</span></div>"
    }

    private func userHTML(_ turn: ChatTurn) -> String {
        let msg = turn.userMessage
        var inner = ""

        for data in msg.imageAttachments {
            let b64 = data.base64EncodedString()
            inner += "<img class=\"attach-img\" src=\"data:image/jpeg;base64,\(b64)\">"
        }
        for name in msg.fileAttachmentNames {
            inner += "<div class=\"attach-file\">\(Self.docSVG) <span>\(MarkdownHTMLRenderer.escape(name))</span></div>"
        }
        if let text = msg.message.content, !text.isEmpty {
            inner += mdContent(text, cls: "user-bubble")
        }
        if turn.isSending {
            inner += "<div class=\"user-meta\"><span class=\"spinner sm\"></span>Sending…</div>"
        } else {
            inner += "<div class=\"user-meta\">\(MarkdownHTMLRenderer.escape(Self.relativeDate(msg.message.timestamp)))</div>"
        }

        guard !inner.isEmpty else { return "" }
        return "<div class=\"user\"><div class=\"user-col\">\(inner)</div></div>"
    }

    private func assistantHTML(_ turn: ChatTurn) -> String {
        let reasoning = reasoningText(turn)
        guard !turn.blocks.isEmpty || reasoning != nil else { return "" }

        var html = "<div class=\"assistant\">"
        if let reasoning {
            html += reasoningHTML(reasoning)
        }
        for block in turn.blocks {
            switch block {
            case .text(_, let content, let isStreaming):
                html += mdContent(content, cls: "md")
                if !isStreaming {
                    html += actionsHTML(text: content, modelID: turn.assistantModelID)
                }
            case .tool(let entry):
                html += toolHTML(entry)
            }
        }
        html += "</div>"
        return html
    }

    private func reasoningHTML(_ text: String) -> String {
        """
        <div class="reasoning collapsible"><div class="reasoning-head" onclick="toggleCollapsible(this)">\
        \(Self.brainSVG)<span>Reasoning</span>\(Self.chevSVG)</div>\
        <div class="collapse"><div class="collapse-inner"><div class="reasoning-body">\(MarkdownHTMLRenderer.escape(text))</div></div></div></div>
        """
    }

    private func actionsHTML(text: String, modelID: String?) -> String {
        var row = "<div class=\"actions\">"
        if let modelID, !modelID.isEmpty {
            row += "<span class=\"model\">\(MarkdownHTMLRenderer.escape(modelID))</span>"
        }
        row += "<button class=\"copy\" data-copy=\"\(Self.percentEncode(text))\" onclick=\"copyFromAttr(event,this)\">\(Self.copySVG)</button>"
        row += "</div>"
        return row
    }

    private func toolHTML(_ entry: ChatTurn.ToolEntry) -> String {
        // Hermes gates dangerous commands: the tool *result* carries
        // `approval_pending: true` (the run finishes without executing — there's no
        // separate approval SSE event, and session-stream runs aren't approvable via
        // the Runs API). So surface it inline as a distinct "Approval required" state
        // with the command + reason, instead of a silent completed tool.
        let approval = entry.output.flatMap(approvalInfo(from:))

        let stateClass = approval != nil ? "approval" : (entry.isRunning ? "running" : "done")
        let name = MarkdownHTMLRenderer.escape(ToolCallFormatting.displayName(entry.name))
        let badge = "<span class=\"tool-badge \(stateClass)\">\(approval != nil ? Self.warnSVG : Self.wrenchSVG)</span>"
        let pill: String
        if approval != nil {
            pill = "<span class=\"tool-pill approval\">\(Self.warnSVG)Approval required</span>"
        } else if entry.isRunning {
            pill = "<span class=\"tool-pill running\"><span class=\"spinner sm\"></span>Running</span>"
        } else {
            pill = "<span class=\"tool-pill done\">\(Self.checkSVG)Done</span>"
        }

        var detail = ""
        if let approval {
            let cmd = MarkdownHTMLRenderer.escape(approval.command)
            let reason = MarkdownHTMLRenderer.escape(approval.description)
            detail += "<div class=\"tool-section\"><div class=\"approval-note\">Blocked pending approval — approve it on the machine running Hermes for the command to execute.</div>"
            if !cmd.isEmpty { detail += "<pre class=\"tool-block\">\(cmd)</pre>" }
            if !reason.isEmpty { detail += "<div class=\"approval-reason\">Reason: \(reason)</div>" }
            detail += "</div>"
        }
        if let args = entry.arguments, !args.isEmpty {
            detail += "<div class=\"tool-section\"><div class=\"tool-label\">Input</div><pre class=\"tool-block\">\(MarkdownHTMLRenderer.escape(args))</pre></div>"
        }
        if approval == nil, let output = entry.output, !output.isEmpty {
            let clean = ToolCallFormatting.cleanOutput(output)
            detail += "<div class=\"tool-section\"><div class=\"tool-label\">Output</div><pre class=\"tool-block\">\(MarkdownHTMLRenderer.escape(clean))</pre></div>"
        } else if let progress = entry.progress?.trimmingCharacters(in: .whitespacesAndNewlines), !progress.isEmpty {
            detail += "<div class=\"tool-section\"><div class=\"tool-label\">Progress</div><pre class=\"tool-block\">\(MarkdownHTMLRenderer.escape(progress))</pre></div>"
        }

        if detail.isEmpty {
            return "<div class=\"tool \(stateClass)\"><div class=\"tool-head\">\(badge)<span class=\"tool-name\">\(name)</span>\(pill)</div></div>"
        }
        // Auto-expand the approval case so the user sees the blocked command immediately.
        let openClass = approval != nil ? " open" : ""
        return """
        <div class="tool \(stateClass) collapsible\(openClass)"><div class="tool-head" onclick="toggleCollapsible(this)">\
        \(badge)<span class="tool-name">\(name)</span>\(pill)\(Self.chevSVG)</div>\
        <div class="collapse"><div class="collapse-inner"><div class="tool-detail">\(detail)</div></div></div></div>
        """
    }

    private struct ApprovalInfo { let command: String; let description: String }

    /// Parses a terminal tool result for Hermes's pending-approval marker. Returns the
    /// command + risk description when the result is `approval_pending`, else nil.
    private func approvalInfo(from output: String) -> ApprovalInfo? {
        guard output.contains("approval_pending") || output.contains("pending_approval"),
              let data = output.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let pending = (obj["approval_pending"] as? Bool == true) || (obj["status"] as? String == "pending_approval")
        guard pending else { return nil }
        return ApprovalInfo(
            command: (obj["command"] as? String) ?? "",
            description: (obj["description"] as? String) ?? (obj["pattern_key"] as? String) ?? ""
        )
    }

    private func indicatorHTML(_ turn: ChatTurn, isLast: Bool) -> String {
        guard isLast else { return "" }
        if store.reconnecting {
            return "<div class=\"indicator\"><span class=\"spinner\"></span><span>Reconnecting…</span></div>"
        }
        if store.working, !turn.hasLiveContent {
            return "<div class=\"indicator\"><span class=\"shimmer\"></span><span>Thinking…</span></div>"
        }
        return ""
    }

    private func document(turns: [ChatTurn]) -> String {
        let body = turns.map { turnHTML($0, isLast: $0.id == turns.last?.id) }.joined()
        return Self.htmlShell(body: body)
    }

    private func encode(_ value: some Encodable) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Helpers

    private static func relativeDate(_ timestamp: Double?) -> String {
        guard let timestamp else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: Date(timeIntervalSince1970: timestamp), relativeTo: .now)
    }

    /// Percent-encode for a single-line, JS-decodable (`decodeURIComponent`) data
    /// attribute that preserves newlines/quotes exactly (copy button + markdown source).
    private static func percentEncode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }

    /// The vendored markdown-it library source, loaded from the bundle once. When
    /// present, markdown (tables, nested lists, GFM, …) is rendered in the page by
    /// markdown-it with `html: false` (raw HTML escaped, so agent output can't inject
    /// scripts). When absent, we fall back to the compact Swift `MarkdownHTMLRenderer`.
    private static let markdownLibrary: String? = {
        guard let url = Bundle.main.url(forResource: "markdown-it.min", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return source
    }()

    private static var useJSMarkdown: Bool { markdownLibrary != nil }

    /// A markdown content container: `data-md` (raw source, rendered by markdown-it in
    /// the page) when the library is available, else pre-rendered HTML.
    private func mdContent(_ text: String, cls: String) -> String {
        if Self.useJSMarkdown {
            return "<div class=\"\(cls)\" data-md=\"\(Self.percentEncode(text))\"></div>"
        }
        return "<div class=\"\(cls)\">\(MarkdownHTMLRenderer.html(from: text))</div>"
    }

    // Inline SVGs (currentColor) standing in for the SF Symbols used natively.
    private static let copySVG = #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="11" height="11" rx="2.5"/><path d="M5 15V5a2 2 0 0 1 2-2h8"/></svg>"#
    private static let chevSVG = #"<svg class="chev" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="M9 6l6 6-6 6"/></svg>"#
    private static let checkSVG = #"<svg class="ic" viewBox="0 0 24 24" fill="currentColor"><path d="M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20zm-1.2 14.3l-3.5-3.5 1.4-1.4 2.1 2.1 4.9-4.9 1.4 1.4-6.3 6.3z"/></svg>"#
    private static let wrenchSVG = #"<svg class="ic" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M14.7 6.3a4 4 0 0 0-5.4 5.4L3 18v3h3l6.3-6.3a4 4 0 0 0 5.4-5.4l-2.3 2.3-2.4-.6-.6-2.4 2.3-2.3z"/></svg>"#
    private static let brainSVG = #"<svg class="ic" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M9 3a3 3 0 0 0-3 3 3 3 0 0 0-2 5 3 3 0 0 0 1 5 3 3 0 0 0 5 1V4a1 1 0 0 0-1-1zm6 0a3 3 0 0 1 3 3 3 3 0 0 1 2 5 3 3 0 0 1-1 5 3 3 0 0 1-5 1V4a1 1 0 0 1 1-1z"/></svg>"#
    private static let docSVG = #"<svg class="ic" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><path d="M14 2v6h6"/></svg>"#
    private static let warnSVG = #"<svg class="ic" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z"/><path d="M12 9v4"/><path d="M12 17h.01"/></svg>"#

    // MARK: - HTML shell

    private static func htmlShell(body: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
        <style>
        :root {
          color-scheme: light dark;
          --secondary: color-mix(in srgb, CanvasText 60%, transparent);
          --tertiary: color-mix(in srgb, CanvasText 30%, transparent);
          --quaternary: color-mix(in srgb, CanvasText 16%, transparent);
          --fill: color-mix(in srgb, CanvasText 6%, transparent);
          --fill-strong: color-mix(in srgb, CanvasText 10%, transparent);
          --hairline: color-mix(in srgb, CanvasText 14%, transparent);
          --running: light-dark(#007aff, #0a84ff);
          --done: light-dark(#34c759, #30d158);
          --approval: light-dark(#ff9500, #ff9f0a);
        }
        * { box-sizing: border-box; -webkit-text-size-adjust: 100%; }
        html, body { margin: 0; padding: 0; }
        body {
          font-family: -apple-system, system-ui, sans-serif;
          font-size: 17px; line-height: 1.45;
          background: Canvas; color: CanvasText;
          opacity: 0; transition: opacity .12s ease-in;
          overflow-x: hidden;
          -webkit-user-select: text; user-select: text;
        }
        #container {
          width: 100%; margin: 0;
          /* Inset by the safe area so content doesn't slide under the macOS sidebar
             (reported as env(safe-area-inset-left)) or the home indicator/notch. The
             extra top inset keeps the first message from sliding under the nav bar in
             a short chat. */
          padding-top: calc(20px + env(safe-area-inset-top));
          padding-right: calc(20px + env(safe-area-inset-right));
          padding-bottom: calc(16px + env(safe-area-inset-bottom));
          padding-left: calc(20px + env(safe-area-inset-left));
        }
        .turn { margin-bottom: 16px; }
        .turn > * + * { margin-top: 12px; }

        /* User */
        .user { display: flex; justify-content: flex-end; }
        .user-col { display: flex; flex-direction: column; align-items: flex-end; gap: 4px; max-width: calc(100% - 24px); }
        .user-bubble {
          background: color-mix(in srgb, AccentColor 18%, transparent);
          border-radius: 16px; padding: 10px 12px;
          overflow-wrap: anywhere;
        }
        .user-meta { font-size: 11px; color: var(--tertiary); display: flex; align-items: center; gap: 4px; }
        .attach-img { max-width: 180px; max-height: 180px; border-radius: 16px; object-fit: cover; }
        .attach-file {
          display: flex; align-items: center; gap: 6px; max-width: 240px;
          background: color-mix(in srgb, AccentColor 18%, transparent);
          border-radius: 16px; padding: 8px 12px; font-size: 12px;
        }
        .attach-file span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

        /* Assistant */
        .assistant > * + * { margin-top: 12px; }
        .md { overflow-wrap: anywhere; }
        .actions { display: flex; align-items: center; justify-content: flex-end; gap: 8px; min-height: 32px; }
        .actions .model { font-size: 11px; color: var(--tertiary); max-width: 60%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .copy {
          appearance: none; border: 0; background: none; cursor: pointer;
          color: AccentColor; padding: 6px; width: 32px; height: 32px;
          display: inline-flex; align-items: center; justify-content: center;
        }
        .copy svg { width: 18px; height: 18px; }
        .copy.copied { color: var(--done); }

        /* Markdown */
        .md p:first-child, .user-bubble p:first-child { margin-top: 0; }
        .md p:last-child, .user-bubble p:last-child { margin-bottom: 0; }
        p { margin: 0 0 10px; }
        ul, ol { margin: 8px 0; padding-left: 22px; }
        li { margin: 3px 0; }
        h1,h2,h3,h4,h5,h6 { margin: 14px 0 6px; line-height: 1.25; font-weight: 600; }
        h1 { font-size: 1.4em; } h2 { font-size: 1.25em; } h3 { font-size: 1.1em; }
        pre { background: var(--fill); padding: 10px 12px; border-radius: 8px; overflow-x: auto; }
        pre code { font-family: ui-monospace, SFMono-Regular, monospace; font-size: 14px; background: none; padding: 0; }
        code { font-family: ui-monospace, SFMono-Regular, monospace; font-size: .88em; background: var(--fill-strong); padding: 1px 5px; border-radius: 5px; }
        blockquote { margin: 8px 0; padding-left: 12px; border-left: 3px solid var(--quaternary); color: var(--secondary); }
        a { color: AccentColor; text-decoration: none; }
        hr { border: 0; border-top: 1px solid var(--hairline); margin: 16px 0; }
        .md img, .user-bubble img { max-width: 100%; border-radius: 8px; }
        table { border-collapse: collapse; margin: 8px 0; display: block; overflow-x: auto; max-width: 100%; font-size: 15px; }
        th, td { border: 1px solid var(--hairline); padding: 6px 10px; text-align: left; }
        th { font-weight: 600; background: var(--fill); }

        /* Collapsible (reasoning + tool calls): animated height + chevron, matching
           the native ToolCallView spring(response: .28, dampingFraction: .86). */
        .collapse { display: grid; grid-template-rows: 0fr; transition: grid-template-rows .3s cubic-bezier(.34, 1.08, .64, 1); }
        .collapsible.open > .collapse { grid-template-rows: 1fr; }
        .collapse-inner { overflow: hidden; min-height: 0; }
        .chev { transition: transform .3s cubic-bezier(.34, 1.08, .64, 1); }
        .collapsible.open > .tool-head .chev,
        .collapsible.open > .reasoning-head .chev { transform: rotate(90deg); }

        /* Reasoning */
        .reasoning-head {
          display: flex; align-items: center; gap: 6px; cursor: pointer;
          font-size: 12px; font-weight: 600; color: var(--secondary); min-height: 28px;
          -webkit-user-select: none; user-select: none;
        }
        .reasoning-head .ic { width: 15px; height: 15px; }
        .reasoning-head .chev { width: 12px; height: 12px; margin-left: auto; }
        .reasoning-body { font-family: ui-monospace, SFMono-Regular, monospace; font-size: 13px; color: var(--secondary); white-space: pre-wrap; padding-top: 4px; }

        /* Tool calls */
        .tool {
          background: var(--fill); border: 1px solid var(--hairline); border-left: 3px solid var(--done);
          border-radius: 10px; padding: 8px 12px;
        }
        .tool.running { border-left-color: var(--running); }
        .tool-head { display: flex; align-items: center; gap: 8px; min-height: 28px; cursor: default; -webkit-user-select: none; user-select: none; }
        .collapsible > .tool-head { cursor: pointer; }
        .tool-badge {
          flex: 0 0 auto; width: 24px; height: 24px; border-radius: 50%;
          display: inline-flex; align-items: center; justify-content: center;
          color: var(--done); background: color-mix(in srgb, var(--done) 14%, transparent);
          border: 1px solid color-mix(in srgb, var(--done) 24%, transparent);
        }
        .tool-badge.running { color: var(--running); background: color-mix(in srgb, var(--running) 14%, transparent); border-color: color-mix(in srgb, var(--running) 24%, transparent); }
        .tool-badge .ic { width: 13px; height: 13px; }
        .tool-name { font-size: 15px; font-weight: 500; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .tool-pill {
          margin-left: auto; flex: 0 0 auto; display: inline-flex; align-items: center; gap: 4px;
          font-size: 12px; font-weight: 700; padding: 2px 8px; border-radius: 999px;
          color: var(--done); background: color-mix(in srgb, var(--done) 12%, transparent);
        }
        .tool-pill.running { color: var(--running); background: color-mix(in srgb, var(--running) 12%, transparent); }
        .tool-pill .ic { width: 13px; height: 13px; }
        .tool .chev { width: 12px; height: 12px; color: var(--tertiary); flex: 0 0 auto; }
        .tool-detail { padding-top: 8px; }
        .tool-section + .tool-section { margin-top: 8px; }
        .tool-label { font-size: 12px; font-weight: 700; color: var(--secondary); margin-bottom: 4px; }
        .tool-block { font-family: ui-monospace, SFMono-Regular, monospace; font-size: 12px; color: var(--secondary); background: color-mix(in srgb, CanvasText 5%, transparent); border-radius: 6px; padding: 8px 12px; margin: 0; white-space: pre-wrap; overflow-wrap: anywhere; }

        /* Indicators */
        .indicator { display: flex; align-items: center; gap: 8px; font-size: 16px; color: var(--secondary); }
        .spinner { width: 16px; height: 16px; border: 2px solid currentColor; border-right-color: transparent; border-radius: 50%; animation: spin .7s linear infinite; display: inline-block; }
        .spinner.sm { width: 11px; height: 11px; border-width: 1.5px; }
        @keyframes spin { to { transform: rotate(360deg); } }
        .shimmer { width: 60px; height: 12px; border-radius: 6px; background: linear-gradient(90deg, var(--quaternary), var(--secondary), var(--quaternary)); background-size: 200% 100%; animation: shimmer 1.3s linear infinite; }
        @keyframes shimmer { to { background-position: -200% 0; } }
        .no-response { display: flex; align-items: center; gap: 6px; font-size: 13px; color: var(--tertiary); font-style: italic; }
        .no-response .ic { width: 14px; height: 14px; }
        /* Approval-required tool state (amber) */
        .tool.approval { border-left-color: var(--approval); }
        .tool-badge.approval { color: var(--approval); background: color-mix(in srgb, var(--approval) 14%, transparent); border-color: color-mix(in srgb, var(--approval) 24%, transparent); }
        .tool-pill.approval { color: var(--approval); background: color-mix(in srgb, var(--approval) 14%, transparent); }
        .tool-pill.approval .ic { width: 13px; height: 13px; }
        .approval-note { font-size: 13px; color: CanvasText; margin-bottom: 6px; }
        .approval-reason { font-size: 12px; color: var(--secondary); margin-top: 6px; }

        /* Jump to latest */
        #jump {
          position: fixed; right: 12px; bottom: calc(12px + env(safe-area-inset-bottom));
          width: 36px; height: 36px; border-radius: 18px;
          background: var(--fill-strong); -webkit-backdrop-filter: blur(20px); backdrop-filter: blur(20px);
          border: 1px solid var(--hairline);
          display: none; align-items: center; justify-content: center;
          color: CanvasText; font-size: 17px; cursor: pointer;
          -webkit-user-select: none; user-select: none;
        }
        </style>
        </head>
        <body>
        <div id="container">\(body)</div>
        <div id="jump" onclick="jumpToBottom()">↓</div>
        \(markdownLibrary.map { "<script>\($0)</script>" } ?? "")
        <script>
        var md = (typeof window.markdownit === 'function')
          ? window.markdownit({ html: false, linkify: true, breaks: false, typographer: false })
          : null;
        function renderMarkdown(scope) {
          var nodes = (scope || document).querySelectorAll('[data-md]:not([data-rendered])');
          for (var i = 0; i < nodes.length; i++) {
            var el = nodes[i];
            var src = decodeURIComponent(el.getAttribute('data-md') || '');
            // Per-node try/catch: a single render failure must not blank every
            // following message (they share one render pass on load).
            try {
              if (md) { el.innerHTML = md.render(src); }
              else { var d = document.createElement('div'); d.textContent = src; el.innerHTML = '<p>' + d.innerHTML + '</p>'; }
            } catch (e) {
              var f = document.createElement('div'); f.textContent = src; el.innerHTML = '<p>' + f.innerHTML + '</p>';
            }
            el.setAttribute('data-rendered', '1');
          }
        }
        function nearBottom() {
          var doc = document.documentElement;
          return (doc.scrollHeight - window.scrollY - window.innerHeight) < 48;
        }
        function scrollToBottom() { window.scrollTo(0, document.documentElement.scrollHeight); }
        function jumpToBottom() { window.scrollTo({ top: document.documentElement.scrollHeight, behavior: 'smooth' }); }
        function updateJump() { document.getElementById('jump').style.display = nearBottom() ? 'none' : 'flex'; }
        function appendTurns(htmls) {
          var pinned = nearBottom();
          var c = document.getElementById('container');
          for (var i = 0; i < htmls.length; i++) {
            var d = document.createElement('div');
            d.innerHTML = htmls[i];
            if (d.firstElementChild) c.appendChild(d.firstElementChild);
          }
          renderMarkdown(c);
          if (pinned) scrollToBottom();
          updateJump();
        }
        function replaceLast(html) {
          var pinned = nearBottom();
          var c = document.getElementById('container');
          if (c.lastElementChild) c.lastElementChild.outerHTML = html;
          renderMarkdown(c);
          if (pinned) scrollToBottom();
          updateJump();
        }
        function toggleCollapsible(head) {
          var c = head.parentElement;
          var wasPinned = nearBottom();
          c.classList.toggle('open');
          if (wasPinned) {
            // Keep the bottom anchored as the height animates open/closed.
            var t0 = Date.now();
            var tick = function () { scrollToBottom(); if (Date.now() - t0 < 340) requestAnimationFrame(tick); };
            requestAnimationFrame(tick);
          }
        }
        function copyFromAttr(e, el) {
          e.preventDefault(); e.stopPropagation();
          var t = decodeURIComponent(el.getAttribute('data-copy') || '');
          var done = function () { el.classList.add('copied'); setTimeout(function () { el.classList.remove('copied'); }, 900); };
          if (navigator.clipboard && navigator.clipboard.writeText) {
            navigator.clipboard.writeText(t).then(done, function () { fallbackCopy(t, done); });
          } else { fallbackCopy(t, done); }
        }
        function fallbackCopy(t, done) {
          var ta = document.createElement('textarea');
          ta.value = t; ta.style.position = 'fixed'; ta.style.opacity = '0';
          document.body.appendChild(ta); ta.focus(); ta.select();
          try { document.execCommand('copy'); done(); } catch (e) {}
          document.body.removeChild(ta);
        }
        window.addEventListener('scroll', updateJump, { passive: true });
        window.addEventListener('load', function () {
          renderMarkdown(document);
          scrollToBottom();
          requestAnimationFrame(function () {
            scrollToBottom();
            document.body.style.opacity = 1;
            updateJump();
          });
        });
        </script>
        </body>
        </html>
        """
    }
}

#if canImport(UIKit)
/// Walks outward from `probe`, returning the nearest `WKWebView` found in any
/// ancestor's subtree. Shared by the keyboard-dismiss and drop-interaction installers.
private func nearestWKWebView(from probe: UIView) -> WKWebView? {
    var ancestor: UIView? = probe.superview
    while let current = ancestor {
        if let found = descendantWKWebView(in: current) { return found }
        ancestor = current.superview
    }
    return nil
}

private func descendantWKWebView(in view: UIView) -> WKWebView? {
    if let wk = view as? WKWebView { return wk }
    for sub in view.subviews {
        if let found = descendantWKWebView(in: sub) { return found }
    }
    return nil
}

/// Restores swipe-to-dismiss-keyboard on the timeline WebView's underlying scroll
/// view (`.scrollDismissesKeyboard` can't reach through the SwiftUI WebView wrapper).
private struct WebKeyboardDismissConfigurator: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let probe = UIView(frame: .zero)
        probe.isUserInteractionEnabled = false
        probe.isHidden = true
        return probe
    }

    func updateUIView(_ probe: UIView, context: Context) {
        DispatchQueue.main.async {
            guard let scrollView = nearestWKWebView(from: probe)?.scrollView else { return }
            if scrollView.keyboardDismissMode != .interactive {
                scrollView.keyboardDismissMode = .interactive
            }
        }
    }
}
#endif

#if targetEnvironment(macCatalyst)
/// Attaches a `UIDropInteraction` to the nearest `WKWebView` so that files and
/// images dragged from Finder (or any app) are handled by the app rather than
/// swallowed by WebKit's own drag handling.
private struct WebDropInteractionInstaller: UIViewRepresentable {
    var onDropFiles: ([URL]) -> Void
    var onDropImageData: (Data) -> Void
    var onDragActiveChanged: (Bool) -> Void

    func makeUIView(context: Context) -> UIView {
        let probe = UIView(frame: .zero)
        probe.isUserInteractionEnabled = false
        probe.isHidden = true
        return probe
    }

    func updateUIView(_ probe: UIView, context: Context) {
        context.coordinator.onDropFiles = onDropFiles
        context.coordinator.onDropImageData = onDropImageData
        context.coordinator.onDragActiveChanged = onDragActiveChanged
        DispatchQueue.main.async {
            guard let webView = nearestWKWebView(from: probe),
                  !context.coordinator.isInstalled(on: webView) else { return }
            context.coordinator.install(on: webView)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIDropInteractionDelegate {
        var onDropFiles: ([URL]) -> Void = { _ in }
        var onDropImageData: (Data) -> Void = { _ in }
        var onDragActiveChanged: (Bool) -> Void = { _ in }
        private weak var installedWebView: WKWebView?

        func isInstalled(on webView: WKWebView) -> Bool { installedWebView === webView }

        func install(on webView: WKWebView) {
            installedWebView = webView
            webView.addInteraction(UIDropInteraction(delegate: self))
        }

        func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
            session.hasItemsConforming(toTypeIdentifiers: [UTType.fileURL.identifier, UTType.image.identifier])
        }

        func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
            onDragActiveChanged(true)
            return UIDropProposal(operation: .copy)
        }

        func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) {
            onDragActiveChanged(false)
        }

        func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) {
            onDragActiveChanged(false)
        }

        func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
            onDragActiveChanged(false)
            for item in session.items {
                let provider = item.itemProvider
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
                        guard let self else { return }
                        let url: URL?
                        if let nsURL = item as? NSURL { url = nsURL as URL }
                        else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                        else { url = nil }
                        if let url { DispatchQueue.main.async { self.onDropFiles([url]) } }
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] data, _ in
                        guard let data, let self else { return }
                        DispatchQueue.main.async { self.onDropImageData(data) }
                    }
                }
            }
        }
    }
}

private struct DropTargetOverlay: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8]))
            Label("Drop to Attach", systemImage: "paperclip")
                .font(.headline)
                .foregroundStyle(Color.accentColor)
        }
        .padding()
        .allowsHitTesting(false)
    }
}
#endif

private struct WebTimelineEmptyState: View {
    var body: some View {
        VStack(spacing: Spacing.l) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Start a conversation")
                .font(.title3)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}
