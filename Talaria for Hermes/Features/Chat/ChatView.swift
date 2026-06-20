import SwiftUI

struct ChatView: View {
    let session: Session
    var onCreatedSession: (Session) -> Void = { _ in }
    @Environment(AppModel.self) private var appModel

    @State private var store: ChatStore?
    @State private var showRename: Bool = false
    @State private var showModelPicker: Bool = false
    @State private var renameText: String = ""
    @State private var draftText: String = ""
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let store {
                MessageTimelineView(store: store)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        ChatComposer(
                            text: $draftText,
                            isWorking: store.working,
                            onSend: { text in
                                Task { await self.send(text, store: store) }
                            },
                            onStop: { store.stop() }
                        )
                        .background(.bar)
                    }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.background)
        .toolbar {
            ChatToolbar(
                modelID: appModel.selectedModelID,
                modelLoading: appModel.modelStore.loading,
                isPinned: isPinned,
                showRenameAlert: $showRename,
                showModelPicker: $showModelPicker,
                onCreateSession: createSession,
                onTogglePinned: togglePinned
            )
        }
        .alert("Rename Session", isPresented: $showRename) {
            TextField("Name", text: $renameText)
            Button("Save") { rename() }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showModelPicker) {
            ModelPickerSheet()
        }
        .alert("Error", isPresented: errorBinding) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onChange(of: store?.lastError?.errorDescription) { _, newDescription in
            if let desc = newDescription {
                errorMessage = desc
            }
        }
        .onChange(of: draftText) { _, newValue in
            appModel.preferences.setDraftText(newValue, for: session.id)
        }
        .onChange(of: showRename) { _, isShowing in
            guard isShowing else { return }
            renameText = session.title ?? ""
        }
        .task(id: session.id) { await loadStore() }
        .navigationBarTitleDisplayMode(.inline)
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private var isPinned: Bool {
        appModel.preferences.isSessionPinned(session.id, for: appModel.activeProfile.id)
    }

    @Sendable
    private func loadStore() async {
        let chatStore = appModel.openChat(for: session)
        store = chatStore
        draftText = appModel.preferences.draftText(for: session.id)
        if chatStore.timeline.isEmpty {
            await chatStore.load()
            errorMessage = chatStore.lastError?.errorDescription
        }
    }

    private func send(_ text: String, store: ChatStore) async {
        await store.send(text)
        if let err = store.lastError {
            errorMessage = err.errorDescription
            appModel.haptics.error()
        }
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
