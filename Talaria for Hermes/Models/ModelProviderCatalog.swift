import Foundation

enum ModelProviderCatalog {
    static func groups(
        current: HermesDashboardModel?,
        recentModelIDs: [String],
        modelCatalog: HermesModelCatalogResponse?,
        config: HermesDashboardConfigResponse?
    ) -> [ModelProviderGroup] {
        var buckets: [String: [ModelProviderModel]] = [:]
        var names: [String: String] = [:]
        var providers: [String: String?] = [:]
        var subtitles: [String: String] = [:]
        var seenKeys: Set<String> = []

        func addResolvedModel(
            modelID: String,
            resolved: (id: String, name: String, provider: String?, subtitle: String),
            subtitle: String?
        ) {
            let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            let seenKey = "\(resolved.id.lowercased())|\(trimmed.lowercased())"
            guard !seenKeys.contains(seenKey) else { return }

            seenKeys.insert(seenKey)
            buckets[resolved.id, default: []].append(ModelProviderModel(id: trimmed, subtitle: subtitle))
            names[resolved.id] = resolved.name
            if providers[resolved.id] == nil || resolved.provider != nil {
                providers[resolved.id] = resolved.provider
            }
            subtitles[resolved.id] = preferredSubtitle(existing: subtitles[resolved.id], next: resolved.subtitle)
        }

        func addModel(modelID: String, explicitProvider: String?, ownedBy: String?, subtitle: String?) {
            addResolvedModel(
                modelID: modelID,
                resolved: resolve(modelID: modelID, explicitProvider: explicitProvider, ownedBy: ownedBy),
                subtitle: subtitle
            )
        }

        addPluginCatalog(modelCatalog, addResolvedModel: addResolvedModel)
        addConfigCatalog(config, addResolvedModel: addResolvedModel)

        if let current {
            addModel(
                modelID: current.modelID,
                explicitProvider: current.provider,
                ownedBy: nil,
                subtitle: current.baseURL ?? "Current"
            )
        }

        for recentModelID in recentModelIDs {
            addModel(modelID: recentModelID, explicitProvider: nil, ownedBy: nil, subtitle: "Recent")
        }

        let currentGroupID = current.map {
            resolve(modelID: $0.modelID, explicitProvider: $0.provider, ownedBy: nil).id
        }

        return buckets.map { id, models in
            ModelProviderGroup(
                id: id,
                name: names[id] ?? "Auto",
                provider: providers[id] ?? nil,
                subtitle: subtitles[id] ?? "Server default",
                models: sorted(models, currentModelID: current?.modelID)
            )
        }
        .sorted { lhs, rhs in
            if lhs.id == currentGroupID { return true }
            if rhs.id == currentGroupID { return false }
            if lhs.provider != nil && rhs.provider == nil { return true }
            if lhs.provider == nil && rhs.provider != nil { return false }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// The set of model ids the server actually advertises (provider + config
    /// catalogs only — deliberately excludes the synthesized "current"/"recent"
    /// entries that `groups` adds). Lets callers tell a real, switchable model from
    /// a placeholder like `hermes-agent`. Empty when no catalog is available, in
    /// which case absence shouldn't be read as "invalid".
    static func catalogModelIDs(
        modelCatalog: HermesModelCatalogResponse?,
        config: HermesDashboardConfigResponse?
    ) -> Set<String> {
        var ids: Set<String> = []
        let collect: (String, (id: String, name: String, provider: String?, subtitle: String), String?) -> Void = { modelID, _, _ in
            let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            ids.insert(trimmed)
        }
        addPluginCatalog(modelCatalog, addResolvedModel: collect)
        addConfigCatalog(config, addResolvedModel: collect)
        return ids
    }

    private static func addPluginCatalog(
        _ catalog: HermesModelCatalogResponse?,
        addResolvedModel: (String, (id: String, name: String, provider: String?, subtitle: String), String?) -> Void
    ) {
        guard let providersValue = catalog?.payload["providers"]?.value else { return }

        if let providerRows = providersValue as? [Any] {
            for row in providerRows {
                guard let provider = row as? [String: Any] else { continue }
                addProviderRow(provider, fallbackSlug: nil, addResolvedModel: addResolvedModel)
            }
        } else if let providerMap = providersValue as? [String: Any] {
            for (slug, rawProvider) in providerMap {
                guard let provider = rawProvider as? [String: Any] else { continue }
                addProviderRow(provider, fallbackSlug: slug, addResolvedModel: addResolvedModel)
            }
        }
    }

    private static func addConfigCatalog(
        _ config: HermesDashboardConfigResponse?,
        addResolvedModel: (String, (id: String, name: String, provider: String?, subtitle: String), String?) -> Void
    ) {
        guard let config else { return }
        let payload = config.config.mapValues(\.value)

        if let providers = payload["providers"] as? [String: Any] {
            for (slug, rawProvider) in providers {
                guard let provider = rawProvider as? [String: Any] else { continue }
                addProviderRow(provider, fallbackSlug: slug, addResolvedModel: addResolvedModel)
            }
        }

        if let modelAliases = payload["model_aliases"] as? [String: Any] {
            addModelAliases(modelAliases, addResolvedModel: addResolvedModel)
        }
    }

    private static func addProviderRow(
        _ providerRow: [String: Any],
        fallbackSlug: String?,
        addResolvedModel: (String, (id: String, name: String, provider: String?, subtitle: String), String?) -> Void
    ) {
        guard let slug = string(providerRow["slug"])
            ?? string(providerRow["id"])
            ?? string(providerRow["provider"])
            ?? fallbackSlug
        else { return }

        let modelIDs = modelIDs(from: providerRow["models"])
        guard !modelIDs.isEmpty else { return }

        let name = string(providerRow["name"])
            ?? string(providerRow["label"])
            ?? string(providerRow["display_name"])
            ?? displayName(for: slug)
        let baseURL = string(providerRow["base_url"])
        let isCurrent = bool(providerRow["is_current"]) == true
        let source = string(providerRow["source"])
        let resolved = providerResolved(
            slug: slug,
            name: name,
            subtitle: isCurrent ? "Current provider" : providerSubtitle(source: source)
        )

        for modelID in modelIDs {
            addResolvedModel(modelID, resolved, baseURL)
        }
    }

    private static func addModelAliases(
        _ aliases: [String: Any],
        addResolvedModel: (String, (id: String, name: String, provider: String?, subtitle: String), String?) -> Void
    ) {
        for (alias, rawAlias) in aliases {
            guard let aliasDict = rawAlias as? [String: Any],
                  let modelID = string(aliasDict["model"])
            else { continue }

            let provider = string(aliasDict["provider"])
            let resolved = resolve(modelID: modelID, explicitProvider: provider, ownedBy: nil)
            addResolvedModel(modelID, resolved, "Alias: \(alias)")
        }
    }

    private static func resolve(
        modelID: String,
        explicitProvider: String?,
        ownedBy: String?
    ) -> (id: String, name: String, provider: String?, subtitle: String) {
        if let provider = cleanedProvider(explicitProvider) {
            return providerResolved(slug: provider, name: displayName(for: provider), subtitle: "Configured provider")
        }

        if let provider = providerPrefix(from: modelID) {
            return providerResolved(slug: provider, name: displayName(for: provider), subtitle: "Model prefix")
        }

        if let owner = cleanedProvider(ownedBy) {
            return ("owner:\(canonicalProviderID(owner))", displayName(for: owner), nil, "Server advertised")
        }

        return ("auto", "Auto", nil, "Server default")
    }

    private static func providerResolved(
        slug: String,
        name: String,
        subtitle: String
    ) -> (id: String, name: String, provider: String?, subtitle: String) {
        let provider = cleanedProvider(slug)
        let id = provider.map { "provider:\(canonicalProviderID($0))" } ?? "auto"
        return (id, name, provider, subtitle)
    }

    private static func sorted(_ models: [ModelProviderModel], currentModelID: String?) -> [ModelProviderModel] {
        models.sorted { lhs, rhs in
            if lhs.id == currentModelID { return true }
            if rhs.id == currentModelID { return false }
            return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
    }

    private static func modelIDs(from value: Any?) -> [String] {
        if let modelID = string(value) {
            return [modelID]
        }

        if let models = value as? [String: Any] {
            var ids = Array(models.keys)
            for raw in models.values {
                if let nested = raw as? [String: Any],
                   let modelID = string(nested["id"]) ?? string(nested["model"]) ?? string(nested["name"]) {
                    ids.append(modelID)
                }
            }
            return deduped(ids)
        }

        if let models = value as? [Any] {
            let ids = models.compactMap { raw -> String? in
                if let modelID = string(raw) {
                    return modelID
                }
                if let model = raw as? [String: Any] {
                    return string(model["id"]) ?? string(model["model"]) ?? string(model["name"])
                }
                return nil
            }
            return deduped(ids)
        }

        return []
    }

    private static func deduped(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.lowercased()
            guard !trimmed.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(trimmed)
        }
        return result
    }

    private static func providerPrefix(from modelID: String) -> String? {
        guard let slash = modelID.firstIndex(of: "/"), slash > modelID.startIndex else { return nil }
        return cleanedProvider(String(modelID[..<slash]))
    }

    private static func cleanedProvider(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }

        let lowered = trimmed.lowercased()
        guard lowered != "auto", lowered != "unknown", lowered != "none" else { return nil }
        return trimmed
    }

    private static func canonicalProviderID(_ provider: String) -> String {
        switch provider.lowercased().replacing("_", with: "-") {
        case "codex", "openai-codex":
            return "openai-codex"
        case "opencode", "opencode-zen", "zen":
            return "opencode-zen"
        case "go", "opencode-go", "opencode-go-sub":
            return "opencode-go"
        default:
            return provider.lowercased()
        }
    }

    private static func displayName(for provider: String) -> String {
        switch canonicalProviderID(provider) {
        case "anthropic":
            return "Anthropic"
        case "gemini", "google":
            return "Google"
        case "hermes":
            return "Hermes"
        case "ollama":
            return "Ollama"
        case "openai":
            return "OpenAI"
        case "openai-codex":
            return "Codex"
        case "opencode-go":
            return "OpenCode Go"
        case "opencode-zen":
            return "OpenCode"
        case "openrouter":
            return "OpenRouter"
        default:
            return provider
                .replacing("_", with: " ")
                .replacing("-", with: " ")
                .capitalized
        }
    }

    private static func providerSubtitle(source: String?) -> String {
        switch source {
        case "canonical":
            return "Hermes provider"
        case "config", "configured":
            return "Configured in Hermes"
        case let source? where !source.isEmpty:
            return source.capitalized
        default:
            return "Hermes provider"
        }
    }

    private static func preferredSubtitle(existing: String?, next: String) -> String {
        guard let existing else { return next }
        if next == "Current provider" { return next }
        if existing == "Current provider" { return existing }
        if next == "Configured in Hermes" { return next }
        return existing
    }

    private static func string(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let int = value as? Int {
            return int.formatted()
        }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let bool = value as? Bool {
            return bool
        }
        if let string = value as? String {
            return ["1", "true", "yes"].contains(string.lowercased())
        }
        return nil
    }
}
