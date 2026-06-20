import Foundation

struct MessageListResponse: Codable, Sendable {
    let data: [HermesMessage]
}
