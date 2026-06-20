import Foundation

struct ToolsetInfo: Codable, Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let label: String?
    let description: String?
    let enabled: Bool?
    let configured: Bool?
    let tools: [String]?
}

struct ListResponse<T: Codable>: Codable {
    let data: [T]
}
