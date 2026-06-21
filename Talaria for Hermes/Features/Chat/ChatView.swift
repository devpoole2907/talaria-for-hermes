import PhotosUI
import SwiftUI

struct ChatView: View {
    let session: Session
    var onCreatedSession: (Session) -> Void = { _ in }
    var onShowTools: () -> Void = {}
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase

    @State private var store: ChatStore?
    @State private var showRename: Bool = false
    @State private var showModelPicker: Bool = false
    @State private var renameText: String = ""
    @State private var draftText: String = ""
    @State private var errorMessage: String?

    @State private var attachments: [ComposerAttachment] = []
    @State private var showPhotoPicker: Bool = false
    @State private var showFilePicker: Bool = false
    @State private var photoSelections: [PhotosPickerItem] = []

    var body: some View {
        Group {
            if let store {
                MessageTimelineView(store: store)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
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
                onCreateSession: createSession,
                onTogglePinned: togglePinned,
                onShowTools: onShowTools
            )
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
            if phase == .active { store?.recoverIfNeeded() }
        }
        .onChange(of: draftText) { _, newValue in
            appModel.preferences.setDraftText(newValue, for: session.id)
        }
        .onChange(of: showRename) { _, isShowing in
            guard isShowing else { return }
            renameText = currentSession.title ?? ""
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoSelections, matching: .images)
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true,
            onCompletion: handleFileImport
        )
        .onChange(of: photoSelections) { _, newSelections in
            guard !newSelections.isEmpty else { return }
            Task { await loadPhotoSelections(newSelections) }
        }
        .task(id: session.id) { await loadStore() }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func loadPhotoSelections(_ selections: [PhotosPickerItem]) async {
        for item in selections {
            let data = try? await item.loadTransferable(type: Data.self)
            let name = item.itemIdentifier ?? "Photo \(attachments.count + 1)"
            attachments.append(ComposerAttachment(name: name, kind: .photo, data: data))
        }
        photoSelections = []
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            for url in urls {
                let needsStop = url.startAccessingSecurityScopedResource()
                defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
                let data = try? Data(contentsOf: url)
                attachments.append(ComposerAttachment(name: url.lastPathComponent, kind: .file, data: data))
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
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

    @Sendable
    private func loadStore() async {
        let chatStore = appModel.openChat(for: session)
        store = chatStore
        draftText = appModel.preferences.draftText(for: session.id)
        if chatStore.timeline.isEmpty && !chatStore.loading {
            await chatStore.load()
            errorMessage = chatStore.lastError?.errorDescription
        }
        chatStore.recoverIfNeeded()
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
