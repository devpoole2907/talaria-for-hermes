import Foundation

struct ServerProfile: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var url: URL
    var apiKey: String
    var adminURL: URL?
    var adminUsername: String?
    var adminPassword: String?

    var isDashboardConfigured: Bool {
        adminURL != nil
    }

    init(
        id: UUID = UUID(),
        name: String,
        url: URL,
        apiKey: String,
        adminURL: URL? = nil,
        adminUsername: String? = nil,
        adminPassword: String? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.apiKey = apiKey
        self.adminURL = adminURL
        self.adminUsername = adminUsername
        self.adminPassword = adminPassword
    }

    var dashboardURL: URL? {
        adminURL
    }

    var suggestedDashboardURL: URL? {
        Self.defaultDashboardURL(for: url)
    }

    private static func defaultDashboardURL(for url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme != nil,
              components.host != nil
        else { return nil }

        components.path = ""
        components.query = nil
        components.fragment = nil
        components.port = 9119
        return components.url
    }
}
