import SwiftUI

enum ContentUnavailableViews {
    @MainActor @ViewBuilder
    static func noProfile(onAdd: @escaping () -> Void) -> some View {
        ContentUnavailableView {
            Label("No server", systemImage: "server.rack")
        } description: {
            Text("Add a Hermes server to get started.")
        } actions: {
            Button("Add Server", action: onAdd)
                .buttonStyle(.borderedProminent)
        }
    }

    @MainActor @ViewBuilder
    static func noSessions(onCreate: @escaping () -> Void) -> some View {
        ContentUnavailableView {
            Label("No sessions yet", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("Start a new session to begin a conversation.")
        } actions: {
            Button("New Session", action: onCreate)
                .buttonStyle(.borderedProminent)
        }
    }

    @MainActor @ViewBuilder
    static func connectionError(_ error: HermesError, retry: @escaping () -> Void, onEditServer: (() -> Void)? = nil) -> some View {
        ContentUnavailableView {
            Label("Can't reach the server", systemImage: "wifi.exclamationmark")
        } description: {
            Text(error.errorDescription ?? "Unknown error.")
        } actions: {
            VStack(spacing: 8) {
                Button("Try Again", action: retry)
                    .buttonStyle(.borderedProminent)
                if let onEditServer {
                    Button("Edit Server", action: onEditServer)
                }
            }
        }
    }
}
