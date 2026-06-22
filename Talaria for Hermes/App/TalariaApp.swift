import SwiftUI
import SwiftData

@main
struct TalariaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView(repository: Self.makeRepository())
        }
    }

    /// Builds the ChatRepository backed by the shared PersistenceController.
    /// Returns nil if the container is unexpectedly unavailable (should not happen
    /// after PersistenceController's self-healing init, but guards defensively).
    @MainActor
    private static func makeRepository() -> ChatRepository {
        ChatRepository(container: PersistenceController.shared.container)
    }
}
