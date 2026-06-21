import Foundation
import Observation

@MainActor
@Observable
final class DashboardSetupModel {
    var urlText: String
    var username: String
    var password: String
    var testStatus: SetupModel.TestStatus = .idle
    var isValidating: Bool = false
    var validationError: String?
    var hasAttemptedSubmit: Bool = false

    private let profile: ServerProfile

    init(profile: ServerProfile) {
        self.profile = profile
        self.urlText = profile.adminURL?.absoluteString
            ?? profile.suggestedDashboardURL?.absoluteString
            ?? ""
        self.username = profile.adminUsername ?? ""
        self.password = profile.adminPassword ?? ""
    }

    var canSubmit: Bool {
        !isValidating
        && !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && parsedURL != nil
    }

    var parsedURL: URL? {
        parsedHTTPURL(from: urlText)
    }

    func validateAndBuild() async -> ServerProfile? {
        hasAttemptedSubmit = true

        guard !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            validationError = nil
            return nil
        }

        guard let url = parsedURL else {
            validationError = "Enter a valid dashboard URL, such as http://forge.local:9119."
            return nil
        }

        validationError = nil
        isValidating = false
        testStatus = .idle
        return build(url: url)
    }

    private func build(url: URL) -> ServerProfile {
        ServerProfile(
            id: profile.id,
            name: profile.name,
            url: profile.url,
            apiKey: profile.apiKey,
            adminURL: url,
            adminUsername: username.nilIfBlank,
            adminPassword: password.nilIfBlank
        )
    }

    private func parsedHTTPURL(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard let url = URL(string: candidate),
              url.scheme == "http" || url.scheme == "https",
              url.host?.isEmpty == false
        else { return nil }
        return url
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
