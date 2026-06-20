import SwiftUI

struct ChatToolbar: ToolbarContent {
    let modelID: String
    let modelLoading: Bool
    let isPinned: Bool
    @Binding var showRenameAlert: Bool
    @Binding var showModelPicker: Bool
    var onCreateSession: () -> Void
    var onTogglePinned: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            ChatModelToolbarButton(
                modelID: modelID,
                isLoading: modelLoading,
                action: { showModelPicker = true }
            )
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("New Chat", systemImage: "square.and.pencil", action: onCreateSession)
                .accessibilityLabel("New chat")

            Menu("Session Actions", systemImage: "ellipsis.circle") {
                Button("Rename", systemImage: "pencil", action: { showRenameAlert = true })
                Button(
                    isPinned ? "Unpin Chat" : "Pin Chat",
                    systemImage: isPinned ? "pin.slash" : "pin",
                    action: onTogglePinned
                )
            }
            .accessibilityLabel("Session actions")
        }
    }
}
