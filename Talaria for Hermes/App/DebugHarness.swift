#if DEBUG
import SwiftUI

/// Backend-free launch scenarios for exercising the UI in the running simulator
/// (not just Xcode previews). Enabled with a launch argument, e.g. pass
/// `-TalariaUITestLongChat YES` (optionally `-TalariaUITestTurnCount 200`).
/// Compiled out of release builds.
enum DebugHarness {
    /// True when launched into the seeded long-chat timeline scenario.
    static var isLongChatScenario: Bool {
        UserDefaults.standard.bool(forKey: "TalariaUITestLongChat")
    }

    /// Number of turns to seed (each is a user message + assistant reply).
    static var longChatTurnCount: Int {
        let n = UserDefaults.standard.integer(forKey: "TalariaUITestTurnCount")
        return n > 0 ? n : 150
    }

    /// When set, fires simulated sends automatically on a timer so the
    /// vanishing-on-append behavior can be verified from screenshots alone (UI
    /// automation / tap isn't available in every simulator host).
    static var autoSend: Bool {
        UserDefaults.standard.bool(forKey: "TalariaUITestAutoSend")
    }

    @MainActor
    static var longChatRootView: some View {
        DebugLongChatRootView(turnCount: longChatTurnCount)
    }
}

/// Presents `ChatView` over a store pre-seeded with a long conversation, with a
/// floating button to simulate sends — so vanishing/scroll behavior can be driven
/// and screenshotted without a Hermes backend.
@MainActor
private struct DebugLongChatRootView: View {
    let turnCount: Int

    @State private var appModel: AppModel
    private let session: Session
    private let store: ChatStore

    init(turnCount: Int) {
        self.turnCount = turnCount

        let profile = ServerProfile(
            id: UUID(uuidString: "D84F3F2B-7D6F-44F6-8F58-93E57D0B6C42")!,
            name: "Debug Harness",
            url: URL(string: "http://localhost:8000")!,
            apiKey: "debug-key"
        )
        let defaults = UserDefaults(suiteName: "ai.talaria.debugharness") ?? .standard
        let preferences = AppPreferences(defaults: defaults)
        let model = AppModel(profile: profile, preferences: preferences, profileStore: ServerProfileStore())

        let session = Session(
            id: "debug-long-chat",
            title: "Debug Long Chat",
            source: "debug",
            model: "hermes-agent",
            startedAt: Date.now.addingTimeInterval(-9000).timeIntervalSince1970,
            lastActive: Date.now.timeIntervalSince1970,
            messageCount: turnCount * 2,
            toolCallCount: 0,
            preview: "Seeded long conversation",
            parentSessionId: nil,
            inputTokens: 0,
            outputTokens: 0
        )

        // Seed the cached store before ChatView mounts. ChatView.loadStore only
        // hits the network when the timeline is empty, so a pre-seeded store opens
        // straight into the conversation with no backend call.
        let store = model.openChat(for: session)
        store.debugSeedLongChat(turnCount: turnCount)

        _appModel = State(initialValue: model)
        self.session = session
        self.store = store
    }

    var body: some View {
        NavigationStack {
            ChatView(session: session)
                .environment(appModel)
                .task {
                    guard DebugHarness.autoSend else { return }
                    // Give the timeline a beat to settle at the bottom, then fire a
                    // send: the just-appended turn must stay on screen (not vanish).
                    try? await Task.sleep(for: .seconds(2))
                    store.debugSimulateSend()
                }
                .overlay(alignment: .bottomLeading) {
                    Button {
                        store.debugSimulateSend()
                    } label: {
                        Label("Simulate Send", systemImage: "paperplane.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.leading, 12)
                    .padding(.bottom, 80)
                    .accessibilityIdentifier("debugSimulateSend")
                }
        }
    }
}
#endif
