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
    /// Serializes the model-set + run-start window across all chats so concurrent
    /// turns (multi-agent workflows) can't run on each other's model. See ModelGate.
    let modelGate = ModelGate()

    /// Local-first persistence repository with optional CloudKit sync.
    private(set) var repository: ChatRepository?

    var serverHealth: HealthInfo?
    var capabilities: Capabilities?
    var startupError: HermesError?
    private var chatStores: [String: ChatStore] = [:]

    init(
        profile: ServerProfile,
        preferences: AppPreferences,
        profileStore: ServerProfileStore,
        repository: ChatRepository? = nil
    ) {
        self.activeProfile = profile
        self.preferences = preferences
        self.profileStore = profileStore
        self.haptics = HapticFeedback()

        let c = Self.makeClient(profile: profile, preferences: preferences)
        self.client = c
        // Accept an injected repository (e.g. from TalariaApp's shared container)
        // or nil for the DEBUG harness / unit tests.
        self.repository = repository
        self.sessionStore = SessionStore(client: c, repository: repository, profileID: profile.id.uuidString)
        self.modelStore = ModelStore(client: c)
    }

    // MARK: - Lifecycle

    func start() async {
        startupError = nil
        await LocalNetworkPermissionRequester.request()
        do {
            serverHealth = try await client.health()
        } catch {
            startupError = HermesError(error)
            return
        }
        async let caps: Void = loadCapabilities()
        async let sessions: Void = sessionStore.refresh()
        if activeProfile.isDashboardConfigured {
            await modelStore.refresh()
            seedDefaultModelIfNeeded()
        }
        _ = await (caps, sessions)
    }

    /// On first run against a profile, adopt the server's current model as the
    /// default new chats inherit, so the picker reflects reality before the user
    /// has explicitly picked anything.
    private func seedDefaultModelIfNeeded() {
        guard preferences.defaultSessionModel(for: activeProfile.id) == nil,
              let model = modelStore.currentModel?.modelID, !model.isEmpty,
              // Never adopt a placeholder (e.g. `hermes-agent`) as the default new
              // chats inherit — it isn't a real provider model and every turn that
              // re-applies it would be rejected.
              modelStore.isSelectableModel(model) else { return }
        preferences.setDefaultModelID(model, provider: modelStore.currentModel?.provider, for: activeProfile.id)
    }

    func switchProfile(_ newProfile: ServerProfile) async {
        withAnimation {
            chatStores.removeAll()
            sessionStore.clear()
            activeProfile = newProfile
            let c = Self.makeClient(profile: newProfile, preferences: preferences)
            client = c
            sessionStore = SessionStore(client: c, repository: repository, profileID: newProfile.id.uuidString)
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
        let sessionID = session.id
        let profileID = activeProfile.id.uuidString
        let store = ChatStore(
            client: client,
            sessionID: sessionID,
            profileID: profileID,
            repository: repository,
            onRunCompleted: { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.sessionStore.refresh()
                }
            },
            onTurnStart: { [weak self] in
                await self?.prepareSessionModelForTurn(for: sessionID)
            },
            persistTurnModel: { [weak self] index, model in
                self?.preferences.setTurnModel(model, at: index, for: sessionID)
            },
            turnModelForIndex: { [weak self] index in
                self?.preferences.turnModel(at: index, for: sessionID)
            },
            modelGate: modelGate
        )
        chatStores[sessionID] = store
        return store
    }

    func closeChat() {
        chatStores.removeAll()
    }

    func switchModel(modelID: String, provider: String?) async -> Bool {
        let switched = await modelStore.switchModel(modelID: modelID, provider: provider)
        if switched {
            preferences.rememberModelID(modelID, provider: provider, for: activeProfile.id)
            haptics.success()
        } else {
            haptics.error()
        }
        return switched
    }

    // MARK: - Per-session model
    //
    // Hermes has a single global model but resolves it *fresh at the start of
    // each turn* (verified live — the earlier "sticky session" finding was a
    // history-parroting artifact). So a session can run any model: we record the
    // model the user picked for it and re-apply it as the global right before each
    // of its turns. Picking a model from the toolbar therefore changes both the
    // global default (what new chats inherit) and the current session.

    /// The model to display for a chat: the one chosen for it, else the default
    /// new chats inherit (the last model you explicitly picked), else the live
    /// global. Deliberately NOT the live global first — running an existing chat
    /// reassigns the global to that chat's model, which must not change what a new
    /// chat shows.
    func sessionModelID(for sessionID: String) -> String {
        preferences.sessionModel(for: sessionID)?.model
            ?? preferences.defaultSessionModel(for: activeProfile.id)?.model
            ?? modelStore.displayModelID
    }

    /// Prepares the server's model for a turn of `sessionID` and returns the model
    /// id used (for the response label). A chat with a chosen model uses it; a new
    /// chat adopts the default (your last picked model) and records it as its own.
    /// Called under the kickoff gate (see `ModelGate`), so the global it sets holds
    /// until this turn's run starts and binds it.
    @discardableResult
    func prepareSessionModelForTurn(for sessionID: String) async -> String? {
        guard activeProfile.isDashboardConfigured else {
            return preferences.sessionModel(for: sessionID)?.model
        }
        // The chat's own model, else the default new chats inherit.
        if let target = preferences.sessionModel(for: sessionID)
            ?? preferences.defaultSessionModel(for: activeProfile.id) {
            // Only ever drive the server to a real, switchable model. If the stored
            // id is a placeholder (e.g. an older session that adopted `hermes-agent`),
            // leave the server's global untouched and let it resolve the turn rather
            // than re-pushing an id the provider rejects every time.
            guard modelStore.isSelectableModel(target.model) else { return nil }
            // First turn of a new chat: pin it to the default so later default
            // changes don't retroactively move this chat.
            if preferences.sessionModel(for: sessionID) == nil {
                preferences.setSessionModel(model: target.model, provider: target.provider, for: sessionID)
            }
            await modelStore.applyActiveModel(modelID: target.model, provider: target.provider)
            return target.model
        }
        // No app-side model known yet (fresh install): adopt the live global and
        // seed it as both this chat's model and the default for new chats — but only
        // when it's a real model, so a placeholder global never gets locked in.
        await modelStore.refreshCurrentModel()
        guard let model = modelStore.currentModel?.modelID, !model.isEmpty,
              modelStore.isSelectableModel(model) else { return nil }
        let provider = modelStore.currentModel?.provider
        preferences.setSessionModel(model: model, provider: provider, for: sessionID)
        preferences.setDefaultModelID(model, provider: provider, for: activeProfile.id)
        return model
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
