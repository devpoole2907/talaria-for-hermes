import Foundation

struct ModelListResponse: Codable, Sendable {
    let data: [ModelInfo]
}

struct ModelInfo: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let object: String?
    let ownedBy: String?
}
