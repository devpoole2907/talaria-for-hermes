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
    #if targetEnvironment(macCatalyst)
    @State private var isDragOver = false
    #endif

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
                        }
                        .animation(.easeInOut(duration: 0.25), value: store.pendingApproval != nil)
                    }
                    #if targetEnvironment(macCatalyst)
                    .onDrop(of: [.fileURL, .image], isTargeted: $isDragOver, perform: handleDrop)
                    .overlay { if isDragOver { DropTargetOverlay() } }
                    #endif
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
            // Returning to the foreground: resume any run whose stream was dropped
            // while the app was suspended, instead of leaving it stuck.
            if phase == .active {
                if store?.useRunsAPI == true {
                    store?.recoverRunsAPIRunIfNeeded()
                } else {
                    store?.recoverIfNeeded()
                }
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

    #if targetEnvironment(macCatalyst)
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url: URL?
                    if let nsURL = item as? NSURL {
                        url = nsURL as URL
                    } else if let data = item as? Data {
                        url = URL(dataRepresentation: data, relativeTo: nil)
                    } else {
                        url = nil
                    }
                    guard let url else { return }
                    Task { @MainActor in
                        guard let data = readPickedFile(at: url) else { return }
                        let name = url.lastPathComponent
                        let isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
                        if isImage {
                            appendPhotoData(data, name: name)
                        } else {
                            attachments.append(ComposerAttachment(name: name, kind: .file, data: data))
                        }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let raw = data else { return }
                    Task { @MainActor in
                        appendPhotoData(raw, name: "Image \(attachments.count + 1)")
                    }
                }
            }
        }
        return true
    }
    #endif

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

    /// Reads a picked file's bytes. Picker URLs are security-scoped, and iCloud /
    /// third-party provider files need a coordinated read (and may need downloading
    /// first), so a plain `Data(contentsOf:)` can return nil for them. Coordinate
    /// the read so those cases work instead of silently failing.
    private func readPickedFile(at url: URL) -> Data? {
        let needsStop = url.startAccessingSecurityScopedResource()
        defer { if needsStop { url.stopAccessingSecurityScopedResource() } }

        var coordinatorError: NSError?
        var data: Data?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinatorError) { readURL in
            data = try? Data(contentsOf: readURL)
        }
        return data
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

#if targetEnvironment(macCatalyst)
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
