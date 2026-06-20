import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    var activeProfile: ServerProfile
    private(set) var client: HermesClient

    private(set) var sessionStore: SessionStore
    private(set) var modelStore: ModelStore
    let preferences: AppPreferences
    let profileStore: ServerProfileStore
    let haptics: HapticFeedback

    var serverHealth: HealthInfo?
    var capabilities: Capabilities?
    var startupError: HermesError?
    private var chatStores: [String: ChatStore] = [:]

    init(
        profile: ServerProfile,
        preferences: AppPreferences,
        profileStore: ServerProfileStore
    ) {
        self.activeProfile = profile
        self.preferences = preferences
        self.profileStore = profileStore
        self.haptics = HapticFeedback()

        let c = Self.makeClient(profile: profile, preferences: preferences)
        self.client = c
        self.sessionStore = SessionStore(client: c)
        self.modelStore = ModelStore(client: c)
    }

    // MARK: - Lifecycle

    func start() async {
        startupError = nil
        do {
            serverHealth = try await client.health()
        } catch {
            startupError = HermesError(error)
            return
        }
        async let caps: Void = loadCapabilities()
        async let models: Void = modelStore.refresh()
        async let sessions: Void = sessionStore.refresh()
        _ = await (caps, models, sessions)
    }

    func switchProfile(_ newProfile: ServerProfile) async {
        withAnimation {
            chatStores.removeAll()
            sessionStore.clear()
            activeProfile = newProfile
            let c = Self.makeClient(profile: newProfile, preferences: preferences)
            client = c
            sessionStore = SessionStore(client: c)
            modelStore = ModelStore(client: c)
            preferences.activeProfileID = newProfile.id
        }
        await start()
    }

    // MARK: - Chat

    func openChat(for session: Session) -> ChatStore {
        if let existing = chatStores[session.id] {
            return existing
        }
        let store = ChatStore(
            client: client,
            sessionID: session.id,
            onRunCompleted: { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.sessionStore.refresh()
                }
            }
        )
        chatStores[session.id] = store
        return store
    }

    func closeChat() {
        chatStores.removeAll()
    }

    func switchModel(modelID: String, provider: String?) async -> Bool {
        let switched = await modelStore.switchModel(modelID: modelID, provider: provider)
        if switched {
            preferences.rememberModelID(modelID, for: activeProfile.id)
            haptics.success()
        } else {
            haptics.error()
        }
        return switched
    }

    // MARK: - Private

    private func loadCapabilities() async {
        capabilities = try? await client.capabilities()
    }

    var useSessionStream: Bool {
        capabilities?.features?.sessionChatStreaming == true
        || capabilities == nil  // assume yes when unknown
    }

    var selectedModelID: String {
        modelStore.currentModel?.modelID
            ?? preferences.defaultModelID(for: activeProfile.id)
            ?? "hermes-agent"
    }

    private static func makeClient(profile: ServerProfile, preferences: AppPreferences) -> HermesClient {
        HermesClient(
            baseURL: profile.url,
            apiKey: profile.apiKey,
            sessionKey: preferences.hermesSessionKey,
            adminURL: profile.adminURL,
            adminUsername: profile.adminUsername,
            adminPassword: profile.adminPassword
        )
    }
}
