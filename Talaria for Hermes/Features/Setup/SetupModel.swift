import Foundation
import Observation

@MainActor
@Observable
final class SetupModel {
    enum TestStatus: Equatable, Sendable {
        case idle
        case testing
        case ok(version: String, platform: String?)
        case failed(message: String)
    }

    var name: String = ""
    var urlText: String = ""
    var apiKey: String = ""
    var adminURLText: String = ""
    var adminUsername: String = ""
    var adminPassword: String = ""
    var testStatus: TestStatus = .idle
    var isValidating: Bool = false
    var validationError: String?
    var hasAttemptedSubmit: Bool = false

    var canSubmit: Bool {
        !isValidating
        && !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && parsedURL != nil
        && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && adminURLIsValid
    }

    var parsedURL: URL? {
        parsedHTTPURL(from: urlText)
    }

    var parsedAdminURL: URL? {
        parsedHTTPURL(from: adminURLText)
    }

    var adminURLIsValid: Bool {
        adminURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || parsedAdminURL != nil
    }

    func test() async {
        guard let url = parsedURL else {
            testStatus = .failed(message: "Enter a valid http(s) URL.")
            return
        }
        testStatus = .testing
        let client = HermesClient(
            baseURL: url,
            apiKey: apiKey,
            sessionKey: "talaria:setup-test"
        )
        do {
            let health = try await client.health()
            _ = try await client.capabilities()
            testStatus = .ok(version: health.version ?? "?", platform: health.platform)
        } catch {
            testStatus = .failed(message: HermesError(error).errorDescription ?? "Couldn't reach the server.")
        }
    }

    func build() -> ServerProfile? {
        guard let url = parsedURL else { return nil }
        return ServerProfile(
            name: resolvedName(for: url),
            url: url,
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            adminURL: parsedAdminURL,
            adminUsername: adminUsername.isEmpty ? nil : adminUsername,
            adminPassword: adminPassword.isEmpty ? nil : adminPassword
        )
    }

    func validateAndBuild() async -> ServerProfile? {
        hasAttemptedSubmit = true

        guard !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            validationError = nil
            return nil
        }

        guard let url = parsedURL else {
            validationError = "Enter a valid server URL, such as http://forge.local:8642."
            return nil
        }

        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            validationError = nil
            return nil
        }

        guard adminURLIsValid else {
            validationError = "Enter a valid dashboard URL or leave it blank."
            return nil
        }

        isValidating = true
        validationError = nil
        testStatus = .testing
        defer { isValidating = false }

        let client = HermesClient(
            baseURL: url,
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            sessionKey: "talaria:setup-test",
            adminURL: parsedAdminURL,
            adminUsername: adminUsername.nilIfBlank,
            adminPassword: adminPassword.nilIfBlank
        )

        do {
            let health = try await client.health()
            _ = try await client.capabilities()
            testStatus = .ok(version: health.version ?? "?", platform: health.platform)
            return build()
        } catch {
            let message = HermesError(error).errorDescription ?? "Connection failed."
            validationError = message
            testStatus = .failed(message: message)
            return nil
        }
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

    private func resolvedName(for url: URL) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return url.host ?? "Hermes"
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
