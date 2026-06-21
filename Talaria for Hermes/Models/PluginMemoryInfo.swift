import Foundation

/// Memory configuration from the Talaria plugin's `/memory` endpoint.
struct PluginMemoryInfo: Decodable, Sendable, Equatable {
    let enabled: Bool
    let userProfileEnabled: Bool?
    let provider: String?
    let storagePath: String?
}
