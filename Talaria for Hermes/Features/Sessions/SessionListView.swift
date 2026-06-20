import SwiftUI

struct SessionListView: View {
    @Binding var selectedSession: Session?
    var onCreatedSession: (Session) -> Void = { _ in }

    @Environment(AppModel.self) private var appModel
    @State private var showSettings: Bool = false
    @State private var showServerPicker: Bool = false
    @State private var creatingError: String?
    @State private var sessionToDelete: Session?
    @State private var sessionToRename: Session?
    @State private var renameText: String = ""

    var body: some View {
        Group {
            if let error = appModel.startupError {
                ContentUnavailableViews.connectionError(
                    error,
                    retry: retry,
                    onEditServer: { showServerPicker = true }
                )
            } else if appModel.serverHealth == nil {
                LaunchScreenView(onEditServer: { showServerPicker = true })
            } else if appModel.sessionStore.sessions.isEmpty && !appModel.sessionStore.loading {
                EmptySessionListView(onCreate: createSession)
            } else {
                sessionList
            }
        }
        .toolbar { toolbarContent }
        .navigationTitle("Sessions")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable(action: refresh)
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showServerPicker) { ServerProfilePickerSheet() }
        .alert("Couldn't create session", isPresented: errorBinding) {
            Button("OK", role: .cancel) { creatingError = nil }
        } message: {
            Text(creatingError ?? "")
        }
        .alert("Rename Session", isPresented: renameBinding, presenting: sessionToRename) { session in
            TextField("Name", text: $renameText)
            Button("Save") { rename(session, to: renameText) }
            Button("Cancel", role: .cancel) { sessionToRename = nil }
        } message: { _ in
            EmptyView()
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Servers", systemImage: "server.rack", action: { showServerPicker = true })
                .accessibilityLabel("Switch server")
        }
        ToolbarItem(placement: .topBarTrailing) {
            HStack {
                Button("Settings", systemImage: "gearshape", action: { showSettings = true })
                Button("New Session", systemImage: "plus", action: createSession)
            }
        }
    }

    private var sessionList: some View {
        List(selection: $selectedSession) {
            if !pinnedSessions.isEmpty {
                Section("Pinned") {
                    sessionRows(pinnedSessions)
                }
            }

            if !unpinnedSessions.isEmpty {
                Section(pinnedSessions.isEmpty ? "Recent" : "Chats") {
                    sessionRows(unpinnedSessions)
                }
            }
        }
        .listStyle(.insetGrouped)
        .alert(
            "Delete Session?",
            isPresented: Binding(
                get: { sessionToDelete != nil },
                set: { if !$0 { sessionToDelete = nil } }
            ),
            presenting: sessionToDelete
        ) { session in
            Button("Delete", role: .destructive) { delete(session) }
            Button("Cancel", role: .cancel) { sessionToDelete = nil }
        } message: { session in
            Text("Delete \"\(session.displayTitle)\"? This cannot be undone.")
        }
    }

    @ViewBuilder
    private func sessionRows(_ sessions: [Session]) -> some View {
        ForEach(sessions) { session in
            NavigationLink(value: session) {
                SessionRowView(session: session)
            }
            .swipeActions(edge: .trailing) {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    sessionToDelete = session
                }
            }
            .swipeActions(edge: .leading) {
                Button("Rename", systemImage: "pencil") {
                    renameText = session.title ?? ""
                    sessionToRename = session
                }
                .tint(.orange)
            }
        }
    }

    private var pinnedSessions: [Session] {
        let sessionsByID = Dictionary(uniqueKeysWithValues: appModel.sessionStore.sessions.map { ($0.id, $0) })
        return pinnedSessionIDs.compactMap { sessionsByID[$0] }
    }

    private var unpinnedSessions: [Session] {
        let pinned = Set(pinnedSessionIDs)
        return appModel.sessionStore.sessions.filter { !pinned.contains($0.id) }
    }

    private var pinnedSessionIDs: [String] {
        appModel.preferences.pinnedSessionIDs(for: appModel.activeProfile.id)
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { creatingError != nil }, set: { if !$0 { creatingError = nil } })
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { sessionToRename != nil }, set: { if !$0 { sessionToRename = nil } })
    }

    @Sendable
    private func refresh() async {
        await appModel.sessionStore.refresh()
    }

    private func retry() {
        Task { await appModel.start() }
    }

    private func createSession() {
        Task {
            do {
                let session = try await appModel.sessionStore.create()
                appModel.haptics.success()
                onCreatedSession(session)
                selectedSession = session
            } catch {
                creatingError = HermesError(error).errorDescription
                appModel.haptics.error()
            }
        }
    }

    private func delete(_ session: Session) {
        Task {
            do {
                try await appModel.sessionStore.delete(session)
                appModel.preferences.setSessionPinned(false, sessionID: session.id, for: appModel.activeProfile.id)
                appModel.preferences.setDraftText("", for: session.id)
                if selectedSession?.id == session.id { selectedSession = nil }
                appModel.haptics.success()
            } catch {
                creatingError = HermesError(error).errorDescription
            }
        }
    }

    private func rename(_ session: Session, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            do {
                _ = try await appModel.sessionStore.rename(session, title: trimmed)
                appModel.haptics.success()
            } catch {
                creatingError = HermesError(error).errorDescription
            }
        }
        sessionToRename = nil
    }
}
