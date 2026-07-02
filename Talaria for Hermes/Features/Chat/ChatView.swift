import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ChatView: View {
    let session: Session
    var onCreatedSession: (Session) -> Void = { _ in }
    var onShowTools: () -> Void = {}
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase

    @State private var store: ChatStore?
    @State private var showRename: Bool = false
    @State private var showModelPicker: Bool = false
    @State private var showDebugInfo: Bool = false
    @State private var renameText: String = ""
    @State private var draftText: String = ""
    @State private var errorMessage: String?

    @State private var attachments: [ComposerAttachment] = []
    @State private var showPhotoPicker: Bool = false
    @State private var showFilePicker: Bool = false
    @State private var photoSelections: [PhotosPickerItem] = []
    @State private var isDragOver = false

    var body: some View {
        Group {
            if let store {
                MessageTimelineWebView(store: store)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        VStack(spacing: 0) {
                            // Actionable approval card (Runs API path only).
                            // Shown above the composer when the agent is waiting for consent.
                            if let approval = store.pendingApproval {
                                ApprovalCardView(approval: approval) { choice in
                                    store.approveRun(choice: choice)
                                }
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                            ChatComposer(
                                text: $draftText,
                                attachments: $attachments,
                                isWorking: store.working,
                                onSend: { text in
                                    Task { await self.send(text, store: store) }
                                },
                                onStop: { store.stop() },
                                onAttachPhoto: { showPhotoPicker = true },
                                onAttachFile: { showFilePicker = true }
                            )
                            .overlay {
                                if isDragOver {
                                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                                        .strokeBorder(Color.accentColor, lineWidth: 2)
                                        .padding(.horizontal, Spacing.m)
                                        .padding(.vertical, Spacing.xs)
                                        .allowsHitTesting(false)
                                }
                            }
                            // SwiftUI `.onDrop` and an overlay UIDropInteraction both lose
                            // to the message TextField's own built-in drop handling on
                            // Catalyst (a dropped CSV pastes its text into the field). The
                            // reliable fix is to hook that text field's *own* drop pipeline
                            // via textDropDelegate and tell UIKit the delegate performs the
                            // drop — so files/images become attachments and no text inserts.
                            .background(
                                ComposerTextDropInstaller(
                                    onDropFile: { data, name in
                                        attachments.append(ComposerAttachment(name: name, kind: .file, data: data))
                                    },
                                    onDropImage: { data, name in appendPhotoData(data, name: name) },
                                    onTargetedChanged: { isDragOver = $0 }
                                )
                            )
                        }
                        .animation(.easeInOut(duration: 0.25), value: store.pendingApproval != nil)
                    }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.background)
        .toolbar {
            ChatToolbar(
                modelID: appModel.sessionModelID(for: session.id),
                modelLoading: appModel.modelStore.loading,
                isPinned: isPinned,
                showRenameAlert: $showRename,
                showModelPicker: $showModelPicker,
                showDebugInfo: $showDebugInfo,
                onCreateSession: createSession,
                onTogglePinned: togglePinned,
                onShowTools: onShowTools
            )
        }
        .alert("Debug Info", isPresented: $showDebugInfo) {
            Button("Copy") { UIPasteboard.general.string = debugInfoDetailed }
            Button("OK", role: .cancel) {}
        } message: {
            Text(debugInfoText)
        }
        .alert("Rename Session", isPresented: $showRename) {
            TextField("Name", text: $renameText)
            Button("Save") { rename() }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showModelPicker) {
            ModelPickerSheet(
                selectedModelID: appModel.sessionModelID(for: session.id),
                onSelectModel: selectModel
            )
        }
        .alert("Error", isPresented: errorBinding) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onChange(of: store?.lastError?.errorDescription) { _, newDescription in
            if let desc = newDescription {
                errorMessage = desc
                // Consume it so navigating away and back doesn't replay a stale alert.
                store?.lastError = nil
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // Returning to the foreground: end the background-task assertion (the
                // socket either survived the grace period or dropped and recovery is
                // about to re-attach it), then resume any run whose stream was dropped
                // while the app was suspended.
                store?.endBackgroundGrace()
                if store?.useRunsAPI == true {
                    store?.recoverRunsAPIRunIfNeeded()
                } else {
                    store?.recoverIfNeeded()
                }
            case .inactive, .background:
                // Moving to the background (or through inactive on the way there): take
                // a UIApplication background-task assertion so iOS grants ~30 s of extra
                // CPU time. That keeps the SSE socket alive across brief app-switches,
                // avoiding the server-side stream teardown entirely for short absences.
                store?.beginBackgroundGraceIfWorking()
            @unknown default:
                break
            }
        }
        .onChange(of: draftText) { _, newValue in
            appModel.preferences.setDraftText(newValue, for: session.id)
        }
        .onChange(of: showRename) { _, isShowing in
            guard isShowing else { return }
            renameText = currentSession.title ?? ""
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoSelections, matching: .images)
        .background {
            DocumentPicker(
                isPresented: $showFilePicker,
                onPick: { urls in attachFiles(at: urls) }
            )
        }
        .onChange(of: photoSelections) { _, newSelections in
            guard !newSelections.isEmpty else { return }
            Task { await loadPhotoSelections(newSelections) }
        }
        .onAppear {
            // `.task(id:)` is unreliable across `.id()`-driven view swaps inside
            // NavigationSplitView (starting a new chat from within one sometimes
            // leaves it stuck on the spinner). onAppear fires dependably on the new
            // identity, so set the store here too — openChat is cached/idempotent.
            if store == nil { store = appModel.openChat(for: session) }
        }
        .task(id: session.id) { await loadStore() }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func loadPhotoSelections(_ selections: [PhotosPickerItem]) async {
        var failures: [String] = []
        for item in selections {
            do {
                guard let raw = try await item.loadTransferable(type: Data.self) else {
                    failures.append(loadErrorDetail("photo returned no data"))
                    continue
                }
                let name = item.itemIdentifier ?? "Photo \(attachments.count + 1)"
                appendPhotoData(raw, name: name)
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        photoSelections = []
        if !failures.isEmpty {
            errorMessage = "Couldn't load \(failures.count == 1 ? "the photo" : "\(failures.count) photos"): \(failures.joined(separator: "; "))"
        }
    }

    private func loadErrorDetail(_ fallback: String) -> String {
        #if targetEnvironment(macCatalyst)
        return "\(fallback) (macOS). Check the app's Photos access in System Settings › Privacy."
        #else
        return fallback
        #endif
    }

    /// Downscales and appends image bytes as a photo attachment.
    /// Shared by the photo picker and the drag-and-drop handler.
    private func appendPhotoData(_ raw: Data, name: String) {
        // Downscale before it rides inline as base64 — full-res photos blow past
        // the server's body limit (HTTP 413). Falls back to raw if not decodable.
        let data = ImageDownscaler.prepareForUpload(raw) ?? raw
        attachments.append(ComposerAttachment(name: name, kind: .photo, data: data))
    }

    private func attachFiles(at urls: [URL]) {
        var failed: [String] = []
        for url in urls {
            if let data = readPickedFile(at: url) {
                attachments.append(ComposerAttachment(name: url.lastPathComponent, kind: .file, data: data))
            } else {
                // Don't append a dataless attachment: it would show a chip that
                // silently drops on send (the upload filter needs non-nil data).
                failed.append(url.lastPathComponent)
            }
        }
        if !failed.isEmpty {
            errorMessage = "Couldn't read \(failed.joined(separator: ", ")). If it's in iCloud Drive, open it once to download it, then try again."
        }
    }

    private func readPickedFile(at url: URL) -> Data? {
        SecurityScopedFileReader.read(url)
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private var isPinned: Bool {
        appModel.preferences.isSessionPinned(session.id, for: appModel.activeProfile.id)
    }

    private var currentSession: Session {
        appModel.sessionStore.session(id: session.id) ?? session
    }

    /// Human-readable debug snapshot for the Info alert. Surfaces the session id plus
    /// the local vs. server message picture (useful when an agent reply is missing on
    /// load) and the run/connection state.
    private var debugInfoText: String {
        let s = currentSession
        let messages = store?.timeline ?? []
        let assistantCount = messages.filter { $0.message.role == "assistant" }.count
        let userCount = messages.filter { $0.message.role == "user" }.count
        let lastRole = messages.last?.message.role ?? "—"

        var lines: [String] = []
        lines.append("Session ID: \(s.id)")
        lines.append("Title: \(s.title ?? "—")")
        lines.append("Source: \(s.source ?? "—")")
        lines.append("Model: \(appModel.sessionModelID(for: s.id))")
        if let parent = s.parentSessionId { lines.append("Parent: \(parent)") }
        let assistants = messages.filter { $0.message.role == "assistant" }
        let emptyContent = assistants.filter { ($0.message.content ?? "").isEmpty }.count
        let withReasoning = assistants.filter { !(($0.message.reasoning ?? $0.message.reasoningContent) ?? "").isEmpty }.count
        let roleCounts = Dictionary(grouping: messages, by: { $0.message.role })
            .mapValues(\.count).sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: ", ")

        lines.append("Server messages: \(s.messageCount.map(String.init) ?? "—")")
        lines.append("Loaded messages: \(messages.count) (user \(userCount) / assistant \(assistantCount))")
        lines.append("Roles: \(roleCounts)")
        lines.append("Assistant empty-content: \(emptyContent), with-reasoning: \(withReasoning)")
        lines.append("Turns: \(store?.turns.count ?? 0)")
        lines.append("Last message role: \(lastRole)")
        lines.append("Run ID: \(store?.currentRunID ?? "—")")
        lines.append("State: working=\(store?.working ?? false) reconnecting=\(store?.reconnecting ?? false) loading=\(store?.loading ?? false)")
        if let usage = store?.lastUsage {
            lines.append("Last usage: in \(usage.input ?? 0) / out \(usage.output ?? 0)")
        }
        lines.append("Session streaming: \(appModel.useSessionStream)")
        lines.append("Server: \(appModel.activeProfile.name) — \(appModel.activeProfile.url.absoluteString)")
        return lines.joined(separator: "\n")
    }

    /// Verbose copy: the summary plus a per-message dump (role, content/reasoning
    /// lengths, tool calls, finish reason) so a missing reply can be pinpointed.
    private var debugInfoDetailed: String {
        let messages = store?.timeline ?? []
        var lines = [debugInfoText, "", "Messages:"]
        for (i, tm) in messages.enumerated() {
            let m = tm.message
            let reasoningLen = ((m.reasoning ?? m.reasoningContent) ?? "").count
            lines.append("[\(i)] \(m.role) content=\((m.content ?? "").count) reasoning=\(reasoningLen) tools=\(m.toolCalls?.count ?? 0) finish=\(m.finishReason ?? "-")")
        }
        return lines.joined(separator: "\n")
    }

    @Sendable
    private func loadStore() async {
        let chatStore = appModel.openChat(for: session)
        store = chatStore
        draftText = appModel.preferences.draftText(for: session.id)
        if chatStore.timeline.isEmpty && !chatStore.loading {
            await chatStore.load()
            errorMessage = chatStore.lastError?.errorDescription
        }
        // Recovery must run on every open — not just when load() ran. On a cold
        // relaunch the timeline is hydrated synchronously from local persistence
        // (so it's non-empty and load() is skipped), and scenePhase doesn't fire
        // .onChange for the initial launch. Without this call a run that was paused
        // for approval (or streaming) when the app was killed is never reconnected
        // and its approval card never reappears. The recovery guards are idempotent,
        // so this is a no-op when load() already kicked it off.
        if chatStore.useRunsAPI {
            chatStore.recoverRunsAPIRunIfNeeded()
        } else {
            chatStore.recoverIfNeeded()
        }
    }

    private func send(_ text: String, store: ChatStore) async {
        // The REST API doesn't execute slash commands (it feeds them to the LLM),
        // so the app intercepts recognized ones and handles them itself.
        if let command = SlashCommand.parse(text) {
            await handleSlash(command, store: store)
            return
        }
        let outgoing = attachments
        attachments = []
        await store.send(text, attachments: outgoing)
        if let err = store.lastError {
            // Plugin-aware so a failed attachment upload (missing/old plugin or
            // unconfigured dashboard) reads as actionable guidance, not a bare 404.
            errorMessage = outgoing.isEmpty ? err.errorDescription : err.pluginGuidanceDescription
            appModel.haptics.error()
        }
    }

    // MARK: - Slash commands

    private func handleSlash(_ command: SlashCommand, store: ChatStore) async {
        appModel.haptics.selection()
        switch command {
        case .model:
            showModelPicker = true
        case .newSession:
            createSession()
        case .title(let newTitle):
            if let newTitle {
                await renameDirect(newTitle)
            } else {
                renameText = currentSession.title ?? ""
                showRename = true
            }
        case .tools:
            onShowTools()
        case .status:
            store.appendLocalExchange(command: "/status", result: await statusText())
        case .skills:
            store.appendLocalExchange(command: "/skills", result: await skillsText())
        case .memory:
            store.appendLocalExchange(command: "/memory", result: await memoryText())
        case .help:
            store.appendLocalExchange(command: "/help", result: Self.helpText)
        }
    }

    private func renameDirect(_ title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try await appModel.sessionStore.rename(session, title: trimmed)
            appModel.haptics.success()
        } catch {
            errorMessage = HermesError(error).errorDescription
            appModel.haptics.error()
        }
    }

    private func statusText() async -> String {
        guard appModel.activeProfile.isDashboardConfigured else { return Self.dashboardNotConfiguredText }
        await appModel.modelStore.refresh()
        if let err = appModel.modelStore.adminError {
            return err.pluginGuidanceDescription
        }
        let model = appModel.modelStore.currentModel
        var rows = ["| Field | Value |", "| --- | --- |"]
        rows.append("| Model | `\(model?.modelID ?? "—")` |")
        if let provider = model?.provider, !provider.isEmpty {
            rows.append("| Provider | \(provider) |")
        }
        if let ctx = model?.contextLength, ctx > 0 {
            rows.append("| Context | \(ctx.formatted()) tokens |")
        }
        return "**Status**\n\n" + rows.joined(separator: "\n")
    }

    private func skillsText() async -> String {
        guard appModel.activeProfile.isDashboardConfigured else { return Self.dashboardNotConfiguredText }
        do {
            let skills = try await appModel.client.dashboardSkills()
            guard !skills.isEmpty else { return "_No skills are installed._" }
            let grouped = Dictionary(grouping: skills) { Self.prettyCategory($0.category) }
            var sections: [String] = ["**Skills** — \(skills.count) installed across \(grouped.count) categories"]
            for category in grouped.keys.sorted() {
                let names = (grouped[category] ?? []).map(\.name).sorted()
                let bullets = names.map { "- \($0)" }.joined(separator: "\n")
                sections.append("**\(category)** · \(names.count)\n\(bullets)")
            }
            return sections.joined(separator: "\n\n")
        } catch {
            return HermesError(error).pluginGuidanceDescription
        }
    }

    private func memoryText() async -> String {
        guard appModel.activeProfile.isDashboardConfigured else { return Self.dashboardNotConfiguredText }
        do {
            let memory = try await appModel.client.pluginMemoryInfo()
            var rows = ["| Field | Value |", "| --- | --- |"]
            rows.append("| Enabled | \(memory.enabled ? "Yes" : "No") |")
            if let profile = memory.userProfileEnabled {
                rows.append("| User profile | \(profile ? "Yes" : "No") |")
            }
            if let provider = memory.provider, !provider.isEmpty {
                rows.append("| Provider | \(provider) |")
            }
            return "**Memory**\n\n" + rows.joined(separator: "\n")
        } catch {
            return HermesError(error).pluginGuidanceDescription
        }
    }

    /// Turns a raw skill category slug (e.g. `autonomous-ai-agents`) into a
    /// human label (`Autonomous AI Agents`), preserving known brand/acronym casing.
    private static func prettyCategory(_ raw: String?) -> String {
        let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "Other" }
        // Special-cased tokens whose canonical casing isn't simple title-case.
        let special: [String: String] = [
            "ai": "AI", "pr": "PR", "mcp": "MCP", "ui": "UI", "api": "API",
            "css": "CSS", "html": "HTML", "gif": "GIF", "llm": "LLM",
            "devops": "DevOps", "mlops": "MLOps", "github": "GitHub",
        ]
        return value
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { word in
                if let mapped = special[word.lowercased()] { return mapped }
                return word.prefix(1).uppercased() + word.dropFirst().lowercased()
            }
            .joined(separator: " ")
    }

    private static let helpText = """
    **Commands**

    - `/model` — switch model
    - `/tools` — toolset controls
    - `/status` — model & runtime status
    - `/skills` — installed skills
    - `/memory` — memory settings
    - `/new` — start a new session
    - `/title <name>` — rename this session
    - `/help` — this list

    _Anything else is sent to the agent._
    """

    private static let dashboardNotConfiguredText =
        "Hermes Dashboard isn't configured. Add the dashboard URL and admin credentials in your server profile to use this command."

    // The model picker sets both the global default (what new chats inherit) and
    // this session's model. Hermes resolves the model fresh each turn, so the app
    // re-applies the session's model as the global before each of its turns (see
    // AppModel.prepareSessionModelForTurn) — that's what makes the switch stick to
    // this chat while other chats keep their own.
    private func selectModel(modelID: String, provider: String?) async -> Bool {
        let switched = await appModel.switchModel(modelID: modelID, provider: provider)
        if switched {
            appModel.preferences.setSessionModel(model: modelID, provider: provider, for: session.id)
        }
        return switched
    }

    private func createSession() {
        Task {
            do {
                let session = try await appModel.sessionStore.create()
                appModel.haptics.success()
                onCreatedSession(session)
            } catch {
                errorMessage = HermesError(error).errorDescription
                appModel.haptics.error()
            }
        }
    }

    private func togglePinned() {
        appModel.preferences.setSessionPinned(!isPinned, sessionID: session.id, for: appModel.activeProfile.id)
        appModel.haptics.selection()
    }

    private func rename() {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            do {
                _ = try await appModel.sessionStore.rename(session, title: trimmed)
                appModel.haptics.success()
            } catch {
                errorMessage = HermesError(error).errorDescription
                appModel.haptics.error()
            }
        }
    }
}

/// Reads a security-scoped / coordinated file URL's bytes. Picker and dropped URLs are
/// security-scoped, and iCloud / third-party provider files need a coordinated read
/// (and may need downloading first), so a plain `Data(contentsOf:)` can return nil for
/// them. Coordinate the read so those cases work instead of silently failing.
enum SecurityScopedFileReader {
    nonisolated static func read(_ url: URL) -> Data? {
        let needsStop = url.startAccessingSecurityScopedResource()
        defer { if needsStop { url.stopAccessingSecurityScopedResource() } }

        var coordinatorError: NSError?
        var data: Data?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinatorError) { readURL in
            data = try? Data(contentsOf: readURL)
        }
        return data
    }
}

/// Adds file/image drag-and-drop to the composer's message field on Mac Catalyst.
///
/// Catalyst routes dropped content two different ways, so we need both halves:
///
/// * **Text-like files** (CSV, plain text, …) reach the text field's own drop pipeline.
///   We become its `textDropDelegate`; for a file we return a proposal whose
///   `dropPerformer` is `.delegate`, so UIKit hands the drop to us (no text inserted)
///   and we attach it. A bare text *selection* still falls through to normal insertion.
/// * **Binary files** (docx, pdf, images, …) are rejected by the text field and never
///   reach `textDropDelegate` at all. For those we add a `UIDropInteraction` to the
///   same text field, which receives every drop type.
///
/// The two paths are partitioned by whether the drop conforms to `public.text`, so a
/// given drop is only ever handled once.
struct ComposerTextDropInstaller: UIViewRepresentable {
    /// Called on the main thread with a non-image file's bytes and name.
    var onDropFile: (Data, String) -> Void
    /// Called on the main thread with image bytes and a name (file image or raw image).
    var onDropImage: (Data, String) -> Void
    /// Drag entered (true) / left or ended (false) — drives the drop-target highlight.
    var onTargetedChanged: (Bool) -> Void

    func makeUIView(context: Context) -> UIView {
        let probe = UIView(frame: .zero)
        probe.isUserInteractionEnabled = false
        probe.isHidden = true
        return probe
    }

    func updateUIView(_ probe: UIView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onDropFile = onDropFile
        coordinator.onDropImage = onDropImage
        coordinator.onTargetedChanged = onTargetedChanged
        // Defer so the text field is in the hierarchy when we search; re-applied on
        // every update so it re-attaches if SwiftUI rebuilds the field.
        DispatchQueue.main.async {
            guard let droppable = Self.nearestTextDroppable(from: probe) else {
                #if DEBUG
                print("[ComposerDrop] no UITextDroppable found yet")
                #endif
                return
            }
            if droppable.textDropDelegate !== coordinator {
                droppable.textDropDelegate = coordinator
                #if DEBUG
                print("[ComposerDrop] attached textDropDelegate to \(type(of: droppable))")
                #endif
            }
            // Add a UIDropInteraction for the binary-file drops that bypass the text
            // pipeline. Only once per field (coordinator tracks where it installed).
            if !coordinator.hasDropInteraction(on: droppable) {
                droppable.addInteraction(UIDropInteraction(delegate: coordinator))
                coordinator.didInstallDropInteraction(on: droppable)
                #if DEBUG
                print("[ComposerDrop] added UIDropInteraction to \(type(of: droppable))")
                #endif
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Walks outward from the probe; the first ancestor subtree containing a text input
    /// is the composer's message field (the probe sits in that composer's background).
    private static func nearestTextDroppable(from probe: UIView) -> (UIView & UITextDroppable)? {
        var ancestor: UIView? = probe.superview
        while let current = ancestor {
            if let found = descendantTextDroppable(in: current) { return found }
            ancestor = current.superview
        }
        return nil
    }

    private static func descendantTextDroppable(in view: UIView) -> (UIView & UITextDroppable)? {
        if let droppable = view as? (UIView & UITextDroppable) { return droppable }
        for sub in view.subviews {
            if let found = descendantTextDroppable(in: sub) { return found }
        }
        return nil
    }

    final class Coordinator: NSObject, UITextDropDelegate, UIDropInteractionDelegate {
        var onDropFile: (Data, String) -> Void = { _, _ in }
        var onDropImage: (Data, String) -> Void = { _, _ in }
        var onTargetedChanged: (Bool) -> Void = { _ in }

        private weak var dropInteractionView: UIView?
        func hasDropInteraction(on view: UIView) -> Bool { dropInteractionView === view }
        func didInstallDropInteraction(on view: UIView) { dropInteractionView = view }

        // MARK: Drop classification

        /// True when the drop carries a file we should attach rather than insert as
        /// text. A bare plain-text *selection* registers only the plain-text UTIs; a
        /// dropped file — even a text-based one like CSV — registers its own concrete
        /// UTI (and/or a file URL / suggested name), which is what we key on.
        private static func isAttachable(_ session: UIDropSession) -> Bool {
            for item in session.items {
                let provider = item.itemProvider
                if provider.suggestedName != nil { return true }
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) { return true }
                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) { return true }
                if provider.registeredTypeIdentifiers.contains(where: { !Self.plainTextTypes.contains($0) }) {
                    return true
                }
            }
            return session.canLoadObjects(ofClass: URL.self)
        }

        /// The drop conforms to `public.text`, so it travels the text field's own drop
        /// pipeline (handled by the `textDropDelegate` half). Used to keep the
        /// `UIDropInteraction` half from double-handling those.
        private static func isTextLike(_ session: UIDropSession) -> Bool {
            session.hasItemsConforming(toTypeIdentifiers: [UTType.text.identifier])
        }

        /// The plain-text UTIs a bare selection registers — these we let the field
        /// insert normally instead of attaching.
        private static let plainTextTypes: Set<String> = [
            "public.text",
            "public.plain-text",
            "public.utf8-plain-text",
            "public.utf16-plain-text",
            "public.utf16-external-plain-text",
        ]

        // MARK: UITextDropDelegate (text-like drops)

        func textDroppableView(_ textDroppableView: UIView & UITextDroppable, proposalForDrop drop: UITextDropRequest) -> UITextDropProposal {
            #if DEBUG
            for item in drop.dropSession.items {
                print("[ComposerDrop] text-proposal name=\(item.itemProvider.suggestedName ?? "nil") types=\(item.itemProvider.registeredTypeIdentifiers)")
            }
            #endif
            guard Self.isAttachable(drop.dropSession) else {
                #if DEBUG
                print("[ComposerDrop] text-proposal -> .copy (let the field insert text)")
                #endif
                return UITextDropProposal(operation: .copy)
            }
            #if DEBUG
            print("[ComposerDrop] text-proposal -> .delegate (we attach it)")
            #endif
            let proposal = UITextDropProposal(operation: .copy)
            proposal.dropPerformer = .delegate // we perform it in willPerformDrop
            return proposal
        }

        func textDroppableView(_ textDroppableView: UIView & UITextDroppable, willPerformDrop drop: UITextDropRequest) {
            #if DEBUG
            print("[ComposerDrop] text-willPerformDrop items=\(drop.dropSession.items.count)")
            #endif
            onTargetedChanged(false)
            for item in drop.dropSession.items { load(item.itemProvider) }
        }

        func textDroppableView(_ textDroppableView: UIView & UITextDroppable, dropSessionDidEnter session: UIDropSession) {
            if Self.isAttachable(session) { onTargetedChanged(true) }
        }

        func textDroppableView(_ textDroppableView: UIView & UITextDroppable, dropSessionDidExit session: UIDropSession) {
            onTargetedChanged(false)
        }

        func textDroppableView(_ textDroppableView: UIView & UITextDroppable, dropSessionDidEnd session: UIDropSession) {
            onTargetedChanged(false)
        }

        // MARK: UIDropInteractionDelegate (binary-file drops)

        func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
            // Text-like drops are handled by the textDropDelegate half; take everything
            // else that's a file/image here so binary types (docx, pdf, …) aren't lost.
            let handled = Self.isAttachable(session) && !Self.isTextLike(session)
            #if DEBUG
            if handled {
                for item in session.items {
                    print("[ComposerDrop] interaction-canHandle types=\(item.itemProvider.registeredTypeIdentifiers)")
                }
            }
            #endif
            return handled
        }

        func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
            UIDropProposal(operation: .copy)
        }

        func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnter session: UIDropSession) {
            onTargetedChanged(true)
        }

        func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) {
            onTargetedChanged(false)
        }

        func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) {
            onTargetedChanged(false)
        }

        func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
            #if DEBUG
            print("[ComposerDrop] interaction-performDrop items=\(session.items.count)")
            #endif
            onTargetedChanged(false)
            for item in session.items { load(item.itemProvider) }
        }

        // MARK: Loading

        /// Loads a dropped item's bytes via its data representation (works for any file
        /// type, including ones that don't vend a `public.file-url`), classifies it as
        /// image or file, and forwards it on the main thread.
        private func load(_ provider: NSItemProvider) {
            let name = provider.suggestedName ?? "Dropped File"
            // Raw image with no backing file (e.g. dragged from a browser).
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
               !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] data, error in
                    #if DEBUG
                    print("[ComposerDrop] image load bytes=\(data?.count ?? -1) error=\(String(describing: error))")
                    #endif
                    guard let self, let data else { return }
                    DispatchQueue.main.async { self.onDropImage(data, name) }
                }
                return
            }
            guard let typeID = Self.fileTypeIdentifier(for: provider) else {
                #if DEBUG
                print("[ComposerDrop] no loadable content type in \(provider.registeredTypeIdentifiers); trying file URL")
                #endif
                loadViaFileURL(provider, fallbackName: name)
                return
            }
            provider.loadDataRepresentation(forTypeIdentifier: typeID) { [weak self] data, error in
                #if DEBUG
                print("[ComposerDrop] file load type=\(typeID) bytes=\(data?.count ?? -1) error=\(String(describing: error))")
                #endif
                guard let self, let data else { return }
                let isImage = UTType(typeID)?.conforms(to: .image) ?? false
                DispatchQueue.main.async {
                    if isImage { self.onDropImage(data, name) }
                    else { self.onDropFile(data, name) }
                }
            }
        }

        /// The richest concrete content type the provider can vend as raw bytes,
        /// skipping URL wrappers (`public.file-url`/`public.url`) whose "bytes" are the
        /// path string rather than the file's contents.
        private static func fileTypeIdentifier(for provider: NSItemProvider) -> String? {
            for id in provider.registeredTypeIdentifiers {
                guard let type = UTType(id) else { continue }
                if type.conforms(to: .url) { continue }
                if type.conforms(to: .data) || type.conforms(to: .content) { return id }
            }
            return nil
        }

        /// Fallback for providers that only vend a file URL: read the file's bytes
        /// while the dropped URL's security-scoped access is still valid.
        private func loadViaFileURL(_ provider: NSItemProvider, fallbackName: String) {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
                guard let self else { return }
                let url: URL?
                if let nsURL = item as? NSURL { url = nsURL as URL }
                else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else { url = nil }
                guard let url, let data = SecurityScopedFileReader.read(url) else { return }
                let name = url.lastPathComponent.isEmpty ? fallbackName : url.lastPathComponent
                let isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
                DispatchQueue.main.async {
                    if isImage { self.onDropImage(data, name) }
                    else { self.onDropFile(data, name) }
                }
            }
        }
    }
}
