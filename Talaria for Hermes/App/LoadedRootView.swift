import SwiftUI

struct LoadedRootView: View {
    @Bindable var appModel: AppModel
    @State private var selectedSession: Session?
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .sidebar

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
            SessionListView(
                selectedSession: $selectedSession,
                onCreatedSession: navigateToSession
            )
        } detail: {
            if let session = selectedSession {
                ChatView(session: session, onCreatedSession: navigateToSession)
                    .id(session.id)
            } else {
                ContentUnavailableView(
                    "Select a Session",
                    systemImage: "message",
                    description: Text("Choose a session from the sidebar or start a new one.")
                )
            }
        }
        .environment(appModel)
        .sensoryFeedback(.success, trigger: appModel.haptics.successTrigger)
        .sensoryFeedback(.warning, trigger: appModel.haptics.warningTrigger)
        .sensoryFeedback(.selection, trigger: appModel.haptics.selectionTrigger)
        .sensoryFeedback(.error, trigger: appModel.haptics.errorTrigger)
        .onChange(of: selectedSession) {
            preferredCompactColumn = selectedSession == nil ? .sidebar : .detail
        }
    }

    private func navigateToSession(_ session: Session) {
        selectedSession = session
        preferredCompactColumn = .detail
    }
}
