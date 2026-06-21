import SwiftUI

struct LoadedRootView: View {
    @Bindable var appModel: AppModel
    @State private var selectedSession: Session?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .sidebar

    var body: some View {
        NavigationSplitView(
            columnVisibility: $columnVisibility,
            preferredCompactColumn: $preferredCompactColumn
        ) {
            SessionListView(
                selectedSession: $selectedSession,
                onCreatedSession: navigateToSession
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
        } content: {
            if let session = selectedSession {
                ChatView(
                    session: session,
                    onCreatedSession: navigateToSession,
                    onShowTools: showTools
                )
                    .id(session.id)
                    .navigationSplitViewColumnWidth(min: 360, ideal: 680)
            } else {
                ContentUnavailableView(
                    "Select a Session",
                    systemImage: "message",
                    description: Text("Choose a session from the sidebar or start a new one.")
                )
            }
        } detail: {
            if let session = selectedSession {
                SessionToolCallsView(session: session)
                    .id(session.id)
                    .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 560)
            } else {
                ContentUnavailableView(
                    "No Tools",
                    systemImage: "wrench.and.screwdriver",
                    description: Text("Tool calls appear after you select a session.")
                )
            }
        }
        .environment(appModel)
        .sensoryFeedback(.success, trigger: appModel.haptics.successTrigger)
        .sensoryFeedback(.warning, trigger: appModel.haptics.warningTrigger)
        .sensoryFeedback(.selection, trigger: appModel.haptics.selectionTrigger)
        .sensoryFeedback(.error, trigger: appModel.haptics.errorTrigger)
        .onChange(of: selectedSession) {
            preferredCompactColumn = selectedSession == nil ? .sidebar : .content
        }
    }

    private func navigateToSession(_ session: Session) {
        selectedSession = session
        columnVisibility = .all
        preferredCompactColumn = .content
    }

    private func showTools() {
        columnVisibility = .all
        preferredCompactColumn = .detail
    }
}
