import SwiftUI

struct ChatToolbar: ToolbarContent {
    let modelID: String
    let modelLoading: Bool
    let isPinned: Bool
    @Binding var showRenameAlert: Bool
    @Binding var showModelPicker: Bool
    @Binding var showDebugInfo: Bool
    var onCreateSession: () -> Void
    var onTogglePinned: () -> Void
    var onShowTools: () -> Void = {}

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            ChatModelToolbarButton(
                modelID: modelID,
                isLoading: modelLoading,
                action: { showModelPicker = true }
            )
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            #if targetEnvironment(macCatalyst)
            Button("New Chat", systemImage: "square.and.pencil", action: onCreateSession)
                .accessibilityLabel("New chat")
            #endif

            Menu("Session Actions", systemImage: "ellipsis.circle") {
                #if !targetEnvironment(macCatalyst)
                Section {
                    Button("New Chat", systemImage: "square.and.pencil", action: onCreateSession)
                }

                Section {
                    Button("Tools", systemImage: "wrench.and.screwdriver", action: onShowTools)
                }
                #endif

                Button("Rename", systemImage: "pencil", action: { showRenameAlert = true })
                Button(
                    isPinned ? "Unpin Chat" : "Pin Chat",
                    systemImage: isPinned ? "pin.slash" : "pin",
                    action: onTogglePinned
                )

                Section {
                    Button("Info", systemImage: "info.circle", action: { showDebugInfo = true })
                }
            }
            .accessibilityLabel("Session actions")
        }
    }
}
