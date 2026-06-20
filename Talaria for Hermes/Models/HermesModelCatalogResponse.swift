import Foundation

struct HermesModelCatalogResponse: Decodable, Sendable {
    let payload: [String: AnyCodable]

    init(from decoder: Decoder) throws {
        payload = try [String: AnyCodable](from: decoder)
    }
}
