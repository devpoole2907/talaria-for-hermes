import Foundation

struct HermesDashboardModel: Decodable, Hashable, Sendable {
    let modelID: String
    let provider: String?
    let baseURL: String?
    let contextLength: Int?

    enum CodingKeys: String, CodingKey {
        case modelID = "model"
        case provider
        case baseURL = "base_url"
        case contextLength = "context_length"
        case effectiveContextLength = "effective_context_length"
        case configContextLength = "config_context_length"
        case autoContextLength = "auto_context_length"
    }

    init(modelID: String, provider: String?, baseURL: String?, contextLength: Int?) {
        self.modelID = modelID
        self.provider = provider
        self.baseURL = baseURL
        self.contextLength = contextLength
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelID = try container.decodeIfPresent(String.self, forKey: .modelID) ?? ""
        provider = try container.decodeIfPresent(String.self, forKey: .provider)
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL)
        contextLength = try container.decodeIfPresent(Int.self, forKey: .effectiveContextLength)
            ?? container.decodeIfPresent(Int.self, forKey: .contextLength)
            ?? container.decodeIfPresent(Int.self, forKey: .configContextLength)
            ?? container.decodeIfPresent(Int.self, forKey: .autoContextLength)
    }
}
