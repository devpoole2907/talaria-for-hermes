import Foundation

struct SkillInfo: Codable, Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let description: String?
    let category: String?
}
