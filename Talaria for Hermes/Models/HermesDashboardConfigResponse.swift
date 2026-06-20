import Foundation

struct HermesDashboardConfigResponse: Decodable, Sendable {
    let config: [String: AnyCodable]

    init(from decoder: Decoder) throws {
        let payload = try [String: AnyCodable](from: decoder)
        if let wrapped = payload["config"]?.value as? [String: Any] {
            config = wrapped.mapValues(AnyCodable.init)
        } else {
            config = payload
        }
    }
}
