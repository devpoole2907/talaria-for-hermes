import Foundation
import Observation

@MainActor
@Observable
final class AppPreferences {
    private let defaults: UserDefaults

    private enum Key {
        static let activeProfileID = "activeProfileID"
        static let hermesSessionKey = "hermesSessionKey"
        static let defaultModelByProfile = "defaultModelByProfile"
        static let defaultModelProviderByProfile = "defaultModelProviderByProfile"
        static let recentModelsByProfile = "recentModelsByProfile"
        static let pinnedSessionsByProfile = "pinnedSessionsByProfile"
        static let draftTextBySession = "draftTextBySession"
        static let modelBySession = "modelBySession"
        static let turnModelsBySession = "turnModelsBySession"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self._activeProfileID = Self.readUUID(defaults, key: Key.activeProfileID)
        self._hermesSessionKey = Self.resolveSessionKey(defaults)
        self._defaultModelByProfile = Self.readModelMap(defaults, key: Key.defaultModelByProfile)
        self._defaultModelProviderByProfile = Self.readModelMap(defaults, key: Key.defaultModelProviderByProfile)
        self._recentModelsByProfile = Self.readRecentModelMap(defaults, key: Key.recentModelsByProfile)
        self._pinnedSessionsByProfile = Self.readStringArrayMap(defaults, key: Key.pinnedSessionsByProfile)
        self._draftTextBySession = Self.readStringMap(defaults, key: Key.draftTextBySession)
        self._modelBySession = Self.readStringDictMap(defaults, key: Key.modelBySession)
        self._turnModelsBySession = Self.readStringArrayMap(defaults, key: Key.turnModelsBySession)
    }

    // MARK: - Active profile

    private var _activeProfileID: UUID?
    var activeProfileID: UUID? {
        get { access(keyPath: \._activeProfileID); return _activeProfileID }
        set {
            withMutation(keyPath: \._activeProfileID) { _activeProfileID = newValue }
            defaults.set(newValue?.uuidString, forKey: Key.activeProfileID)
        }
    }

    // MARK: - Hermes session key

    private var _hermesSessionKey: String
    var hermesSessionKey: String {
        get { access(keyPath: \._hermesSessionKey); return _hermesSessionKey }
    }

    // MARK: - Default model per profile

    private var _defaultModelByProfile: [String: String]
    var defaultModelByProfile: [String: String] {
        get { access(keyPath: \._defaultModelByProfile); return _defaultModelByProfile }
        set {
            withMutation(keyPath: \._defaultModelByProfile) { _defaultModelByProfile = newValue }
            defaults.set(newValue, forKey: Key.defaultModelByProfile)
        }
    }

    private var _defaultModelProviderByProfile: [String: String]
    var defaultModelProviderByProfile: [String: String] {
        get { access(keyPath: \._defaultModelProviderByProfile); return _defaultModelProviderByProfile }
        set {
            withMutation(keyPath: \._defaultModelProviderByProfile) { _defaultModelProviderByProfile = newValue }
            defaults.set(newValue, forKey: Key.defaultModelProviderByProfile)
        }
    }

    func defaultModelID(for profileID: UUID) -> String? {
        defaultModelByProfile[profileID.uuidString]
    }

    /// The default model + provider new chats inherit. Changes only when the user
    /// explicitly picks a model (not when an existing chat runs its own).
    func defaultSessionModel(for profileID: UUID) -> SessionModel? {
        guard let model = defaultModelByProfile[profileID.uuidString]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty
        else { return nil }
        let provider = defaultModelProviderByProfile[profileID.uuidString]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return SessionModel(model: model, provider: provider?.isEmpty == true ? nil : provider)
    }

    func setDefaultModelID(_ modelID: String?, provider: String? = nil, for profileID: UUID) {
        var map = defaultModelByProfile
        var providerMap = defaultModelProviderByProfile
        if let modelID {
            map[profileID.uuidString] = modelID
            if let provider = provider?.trimmingCharacters(in: .whitespacesAndNewlines), !provider.isEmpty {
                providerMap[profileID.uuidString] = provider
            } else {
                providerMap.removeValue(forKey: profileID.uuidString)
            }
        } else {
            map.removeValue(forKey: profileID.uuidString)
            providerMap.removeValue(forKey: profileID.uuidString)
        }
        defaultModelByProfile = map
        defaultModelProviderByProfile = providerMap
    }

    // MARK: - Recent models per profile

    private var _recentModelsByProfile: [String: [String]]
    var recentModelsByProfile: [String: [String]] {
        get { access(keyPath: \._recentModelsByProfile); return _recentModelsByProfile }
        set {
            withMutation(keyPath: \._recentModelsByProfile) { _recentModelsByProfile = newValue }
            defaults.set(newValue, forKey: Key.recentModelsByProfile)
        }
    }

    func recentModelIDs(for profileID: UUID) -> [String] {
        recentModelsByProfile[profileID.uuidString] ?? []
    }

    func rememberRecentModelID(_ modelID: String, for profileID: UUID) {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var map = recentModelsByProfile
        var recent = map[profileID.uuidString] ?? []
        recent.removeAll { $0 == trimmed }
        recent.insert(trimmed, at: 0)
        map[profileID.uuidString] = Array(recent.prefix(8))
        recentModelsByProfile = map
    }

    func rememberModelID(_ modelID: String, provider: String? = nil, for profileID: UUID) {
        rememberRecentModelID(modelID, for: profileID)
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        setDefaultModelID(trimmed, provider: provider, for: profileID)
    }

    // MARK: - Pinned sessions per profile

    private var _pinnedSessionsByProfile: [String: [String]]
    var pinnedSessionsByProfile: [String: [String]] {
        get { access(keyPath: \._pinnedSessionsByProfile); return _pinnedSessionsByProfile }
        set {
            withMutation(keyPath: \._pinnedSessionsByProfile) { _pinnedSessionsByProfile = newValue }
            defaults.set(newValue, forKey: Key.pinnedSessionsByProfile)
        }
    }

    func pinnedSessionIDs(for profileID: UUID) -> [String] {
        pinnedSessionsByProfile[profileID.uuidString] ?? []
    }

    func isSessionPinned(_ sessionID: String, for profileID: UUID) -> Bool {
        pinnedSessionIDs(for: profileID).contains(sessionID)
    }

    func setSessionPinned(_ pinned: Bool, sessionID: String, for profileID: UUID) {
        var map = pinnedSessionsByProfile
        var pinnedIDs = map[profileID.uuidString] ?? []
        pinnedIDs.removeAll { $0 == sessionID }
        if pinned {
            pinnedIDs.insert(sessionID, at: 0)
        }
        map[profileID.uuidString] = pinnedIDs
        pinnedSessionsByProfile = map
    }

    // MARK: - Draft text per session

    private var _draftTextBySession: [String: String]
    var draftTextBySession: [String: String] {
        get { access(keyPath: \._draftTextBySession); return _draftTextBySession }
        set {
            withMutation(keyPath: \._draftTextBySession) { _draftTextBySession = newValue }
            defaults.set(newValue, forKey: Key.draftTextBySession)
        }
    }

    func draftText(for sessionID: String) -> String {
        draftTextBySession[sessionID] ?? ""
    }

    func setDraftText(_ draft: String, for sessionID: String) {
        var map = draftTextBySession
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            map.removeValue(forKey: sessionID)
        } else {
            map[sessionID] = draft
        }
        draftTextBySession = map
    }

    // MARK: - Per-session model

    /// The model+provider chosen for a chat. Hermes resolves its single global
    /// model fresh each turn, so the app re-applies this as the global before each
    /// of the session's turns to make the session run it (see
    /// `AppModel.prepareSessionModelForTurn`). Set from the model picker and
    /// adopted from the global on a chat's first turn if not chosen explicitly.
    struct SessionModel: Sendable, Equatable {
        let model: String
        let provider: String?
    }

    private var _modelBySession: [String: [String: String]]
    var modelBySession: [String: [String: String]] {
        get { access(keyPath: \._modelBySession); return _modelBySession }
        set {
            withMutation(keyPath: \._modelBySession) { _modelBySession = newValue }
            defaults.set(newValue, forKey: Key.modelBySession)
        }
    }

    func sessionModel(for sessionID: String) -> SessionModel? {
        guard let entry = modelBySession[sessionID],
              let model = entry["model"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty
        else { return nil }
        let provider = entry["provider"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return SessionModel(model: model, provider: provider?.isEmpty == true ? nil : provider)
    }

    func setSessionModel(model: String, provider: String?, for sessionID: String) {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { return }
        var map = modelBySession
        var entry: [String: String] = ["model": trimmedModel]
        if let provider = provider?.trimmingCharacters(in: .whitespacesAndNewlines), !provider.isEmpty {
            entry["provider"] = provider
        }
        map[sessionID] = entry
        modelBySession = map
    }

    // MARK: - Per-turn model

    /// The model that produced each turn's response, indexed by the turn's order
    /// position in the conversation. Recorded when a turn runs so the label beside
    /// the copy button stays pinned to the model that actually generated it —
    /// switching the chat's model must never relabel earlier replies, and these
    /// survive reloads (the server doesn't persist per-message model info).
    private var _turnModelsBySession: [String: [String]]
    var turnModelsBySession: [String: [String]] {
        get { access(keyPath: \._turnModelsBySession); return _turnModelsBySession }
        set {
            withMutation(keyPath: \._turnModelsBySession) { _turnModelsBySession = newValue }
            defaults.set(newValue, forKey: Key.turnModelsBySession)
        }
    }

    func turnModel(at index: Int, for sessionID: String) -> String? {
        guard index >= 0, let models = turnModelsBySession[sessionID], index < models.count else { return nil }
        let model = models[index].trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? nil : model
    }

    func setTurnModel(_ model: String, at index: Int, for sessionID: String) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, index >= 0 else { return }
        var map = turnModelsBySession
        var models = map[sessionID] ?? []
        if index >= models.count {
            models.append(contentsOf: repeatElement("", count: index - models.count + 1))
        }
        models[index] = trimmed
        map[sessionID] = models
        turnModelsBySession = map
    }

    // MARK: - Helpers

    private static func readStringDictMap(_ defaults: UserDefaults, key: String) -> [String: [String: String]] {
        guard let raw = defaults.dictionary(forKey: key) else { return [:] }
        var result: [String: [String: String]] = [:]
        for (sessionID, value) in raw {
            if let dict = value as? [String: String] {
                result[sessionID] = dict
            }
        }
        return result
    }

    private static func readUUID(_ defaults: UserDefaults, key: String) -> UUID? {
        guard let raw = defaults.string(forKey: key) else { return nil }
        return UUID(uuidString: raw)
    }

    private static func resolveSessionKey(_ defaults: UserDefaults) -> String {
        if let existing = defaults.string(forKey: Key.hermesSessionKey), !existing.isEmpty {
            return existing
        }
        let key = "talaria:user-\(UUID().uuidString)"
        defaults.set(key, forKey: Key.hermesSessionKey)
        return key
    }

    private static func readModelMap(_ defaults: UserDefaults, key: String) -> [String: String] {
        readStringMap(defaults, key: key)
    }

    private static func readRecentModelMap(_ defaults: UserDefaults, key: String) -> [String: [String]] {
        readStringArrayMap(defaults, key: key)
    }

    private static func readStringMap(_ defaults: UserDefaults, key: String) -> [String: String] {
        defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    private static func readStringArrayMap(_ defaults: UserDefaults, key: String) -> [String: [String]] {
        guard let raw = defaults.dictionary(forKey: key) else { return [:] }
        var result: [String: [String]] = [:]
        for (profileID, value) in raw {
            if let strings = value as? [String] {
                result[profileID] = strings
            }
        }
        return result
    }
}
