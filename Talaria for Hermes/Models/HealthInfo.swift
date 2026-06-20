import Foundation

struct HealthInfo: Codable, Sendable {
    let status: String
    let platform: String?
    let version: String?
}
