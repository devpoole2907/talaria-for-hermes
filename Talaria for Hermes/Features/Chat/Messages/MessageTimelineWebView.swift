import SwiftUI
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

    @State private var page = WebPage()
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
        parts.append(turn.streamingThinking ?? "")
        if isLast { parts.append("w:\(store.working):\(store.reconnecting)") }
        return parts.joined(separator: "|")
    }

    private func turnHTML(_ turn: ChatTurn, isLast: Bool) -> String {
        var html = "<div class=\"turn\" id=\"turn-\(turn.id.uuidString)\">"
        html += userHTML(turn)
        html += assistantHTML(turn)
        html += indicatorHTML(turn, isLast: isLast)
        html += "</div>"
        return html
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
            inner += "<div class=\"user-bubble\">\(MarkdownHTMLRenderer.html(from: text))</div>"
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
        let hasThinking = turn.streamingThinking?.isEmpty == false
        guard !turn.blocks.isEmpty || hasThinking else { return "" }

        var html = "<div class=\"assistant\">"
        if let thinking = turn.streamingThinking, !thinking.isEmpty {
            html += reasoningHTML(thinking)
        }
        for block in turn.blocks {
            switch block {
            case .text(_, let content, let isStreaming):
                html += "<div class=\"md\">\(MarkdownHTMLRenderer.html(from: content))</div>"
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
        <details class="reasoning"><summary>\(Self.brainSVG)<span>Reasoning</span>\(Self.chevSVG)</summary>\
        <div class="reasoning-body">\(MarkdownHTMLRenderer.escape(text))</div></details>
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
        let status = entry.isRunning ? "running" : "done"
        let name = MarkdownHTMLRenderer.escape(ToolCallFormatting.displayName(entry.name))
        let badge = "<span class=\"tool-badge \(status)\">\(Self.wrenchSVG)</span>"
        let pill: String = entry.isRunning
            ? "<span class=\"tool-pill running\"><span class=\"spinner sm\"></span>Running</span>"
            : "<span class=\"tool-pill done\">\(Self.checkSVG)Done</span>"

        var detail = ""
        if let args = entry.arguments, !args.isEmpty {
            detail += "<div class=\"tool-section\"><div class=\"tool-label\">Input</div><pre class=\"tool-block\">\(MarkdownHTMLRenderer.escape(args))</pre></div>"
        }
        if let output = entry.output, !output.isEmpty {
            let clean = ToolCallFormatting.cleanOutput(output)
            detail += "<div class=\"tool-section\"><div class=\"tool-label\">Output</div><pre class=\"tool-block\">\(MarkdownHTMLRenderer.escape(clean))</pre></div>"
        } else if let progress = entry.progress?.trimmingCharacters(in: .whitespacesAndNewlines), !progress.isEmpty {
            detail += "<div class=\"tool-section\"><div class=\"tool-label\">Progress</div><pre class=\"tool-block\">\(MarkdownHTMLRenderer.escape(progress))</pre></div>"
        }

        if detail.isEmpty {
            return "<div class=\"tool \(status)\"><div class=\"tool-head\">\(badge)<span class=\"tool-name\">\(name)</span>\(pill)</div></div>"
        }
        return """
        <details class="tool \(status)"><summary class="tool-head">\(badge)<span class="tool-name">\(name)</span>\(pill)\(Self.chevSVG)</summary>\
        <div class="tool-detail">\(detail)</div></details>
        """
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
    /// attribute that preserves newlines/quotes exactly for the copy button.
    private static func percentEncode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }

    // Inline SVGs (currentColor) standing in for the SF Symbols used natively.
    private static let copySVG = #"<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="11" height="11" rx="2.5"/><path d="M5 15V5a2 2 0 0 1 2-2h8"/></svg>"#
    private static let chevSVG = #"<svg class="chev" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="M9 6l6 6-6 6"/></svg>"#
    private static let checkSVG = #"<svg class="ic" viewBox="0 0 24 24" fill="currentColor"><path d="M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20zm-1.2 14.3l-3.5-3.5 1.4-1.4 2.1 2.1 4.9-4.9 1.4 1.4-6.3 6.3z"/></svg>"#
    private static let wrenchSVG = #"<svg class="ic" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M14.7 6.3a4 4 0 0 0-5.4 5.4L3 18v3h3l6.3-6.3a4 4 0 0 0 5.4-5.4l-2.3 2.3-2.4-.6-.6-2.4 2.3-2.3z"/></svg>"#
    private static let brainSVG = #"<svg class="ic" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M9 3a3 3 0 0 0-3 3 3 3 0 0 0-2 5 3 3 0 0 0 1 5 3 3 0 0 0 5 1V4a1 1 0 0 0-1-1zm6 0a3 3 0 0 1 3 3 3 3 0 0 1 2 5 3 3 0 0 1-1 5 3 3 0 0 1-5 1V4a1 1 0 0 1 1-1z"/></svg>"#
    private static let docSVG = #"<svg class="ic" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><path d="M14 2v6h6"/></svg>"#

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
             (reported as env(safe-area-inset-left)) or the home indicator/notch. */
          padding-top: 16px;
          padding-right: calc(16px + env(safe-area-inset-right));
          padding-bottom: calc(16px + env(safe-area-inset-bottom));
          padding-left: calc(16px + env(safe-area-inset-left));
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

        /* Reasoning */
        details.reasoning { }
        details.reasoning > summary {
          list-style: none; display: flex; align-items: center; gap: 6px; cursor: pointer;
          font-size: 12px; font-weight: 600; color: var(--secondary); min-height: 28px;
        }
        details.reasoning > summary::-webkit-details-marker { display: none; }
        details.reasoning .ic { width: 15px; height: 15px; }
        details.reasoning .chev { width: 12px; height: 12px; transition: transform .2s; margin-left: auto; }
        details.reasoning[open] > summary .chev { transform: rotate(90deg); }
        .reasoning-body { font-family: ui-monospace, SFMono-Regular, monospace; font-size: 13px; color: var(--secondary); white-space: pre-wrap; padding-top: 4px; }

        /* Tool calls */
        .tool {
          background: var(--fill); border: 1px solid var(--hairline); border-left: 3px solid var(--done);
          border-radius: 10px; padding: 8px 12px;
        }
        .tool.running { border-left-color: var(--running); }
        .tool > summary, .tool-head { list-style: none; display: flex; align-items: center; gap: 8px; min-height: 28px; cursor: default; }
        details.tool > summary { cursor: pointer; }
        .tool > summary::-webkit-details-marker { display: none; }
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
        .tool .chev { width: 12px; height: 12px; color: var(--tertiary); transition: transform .2s; flex: 0 0 auto; }
        details.tool[open] > summary .chev { transform: rotate(90deg); }
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
        <script>
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
          if (pinned) scrollToBottom();
          updateJump();
        }
        function replaceLast(html) {
          var pinned = nearBottom();
          var c = document.getElementById('container');
          if (c.lastElementChild) c.lastElementChild.outerHTML = html;
          if (pinned) scrollToBottom();
          updateJump();
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
