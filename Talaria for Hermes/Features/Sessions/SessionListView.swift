import SwiftUI

struct SessionListView: View {
    @Binding var selectedSession: Session?
    var onCreatedSession: (Session) -> Void = { _ in }

    @Environment(AppModel.self) private var appModel
    @State private var showSettings: Bool = false
    @State private var creatingError: String?
    @State private var sessionToDelete: Session?
    @State private var sessionToRename: Session?
    @State private var renameText: String = ""
    @State private var searchText: String = ""

    var body: some View {
        Group {
            if let error = appModel.startupError {
                ContentUnavailableViews.connectionError(
                    error,
                    retry: retry,
                    onEditServer: { showSettings = true }
                )
            } else if appModel.sessionStore.sessions.isEmpty {
                if appModel.serverHealth == nil || appModel.sessionStore.loading {
                    // Still connecting / loading sessions: keep the Sessions screen
                    // and its toolbar on screen with an inline spinner instead of
                    // taking over the whole window with the launch screen.
                    loadingPlaceholder
                } else {
                    EmptySessionListView(onCreate: createSession)
                }
            } else if hasNoSearchResults {
                ContentUnavailableView.search
            } else {
                sessionList
            }
        }
        .toolbar { toolbarContent }
        .navigationTitle("Sessions")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search sessions")
        .refreshable(action: refresh)
        .sheet(isPresented: $showSettings) { SettingsView() }
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
        ToolbarItem(placement: .topBarTrailing) {
            Button("Settings", systemImage: "gearshape", action: { showSettings = true })
        }

        #if os(iOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 26, *) {
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
        }

        ToolbarItemGroup(placement: .bottomBar) {
            Spacer()
            Button("New Session", systemImage: "plus", action: createSession)
        }
        #else
        ToolbarItem(placement: .topBarTrailing) {
            Button("New Session", systemImage: "plus", action: createSession)
        }
        #endif
    }

    private var loadingPlaceholder: some View {
        VStack(spacing: Spacing.m) {
            ProgressView()
            Text("Loading sessions…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            .contextMenu {
                Button("Rename", systemImage: "pencil") {
                    beginRename(session)
                }

                Button(isPinned(session) ? "Unpin" : "Pin", systemImage: isPinned(session) ? "pin.slash" : "pin") {
                    togglePinned(session)
                }

                Divider()

                Button("Delete", systemImage: "trash", role: .destructive) {
                    requestDelete(session)
                }
            } preview: {
                SessionContextPreview(session: session, isPinned: isPinned(session))
            }
            .swipeActions(edge: .trailing) {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    requestDelete(session)
                }
            }
            .swipeActions(edge: .leading) {
                Button(isPinned(session) ? "Unpin" : "Pin", systemImage: isPinned(session) ? "pin.slash" : "pin") {
                    togglePinned(session)
                }
                .tint(.accentColor)

                Button("Rename", systemImage: "pencil") {
                    beginRename(session)
                }
                .tint(.orange)
            }
        }
    }

    private var pinnedSessions: [Session] {
        let sessionsByID = Dictionary(uniqueKeysWithValues: appModel.sessionStore.sessions.map { ($0.id, $0) })
        return filtered(pinnedSessionIDs.compactMap { sessionsByID[$0] })
    }

    private var unpinnedSessions: [Session] {
        let pinned = Set(pinnedSessionIDs)
        return filtered(appModel.sessionStore.sessions.filter { !pinned.contains($0.id) })
    }

    private var hasNoSearchResults: Bool {
        hasSearchQuery && pinnedSessions.isEmpty && unpinnedSessions.isEmpty
    }

    private var hasSearchQuery: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Filters by the native search field, matching the session's display title.
    private func filtered(_ sessions: [Session]) -> [Session] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sessions }
        return sessions.filter { $0.displayTitle.localizedCaseInsensitiveContains(query) }
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

    private func beginRename(_ session: Session) {
        renameText = session.title ?? ""
        sessionToRename = session
    }

    private func isPinned(_ session: Session) -> Bool {
        appModel.preferences.isSessionPinned(session.id, for: appModel.activeProfile.id)
    }

    private func togglePinned(_ session: Session) {
        appModel.preferences.setSessionPinned(!isPinned(session), sessionID: session.id, for: appModel.activeProfile.id)
        appModel.haptics.selection()
    }

    private func requestDelete(_ session: Session) {
        sessionToDelete = session
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
