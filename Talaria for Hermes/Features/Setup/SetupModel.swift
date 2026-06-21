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
    var testStatus: TestStatus = .idle
    var isValidating: Bool = false
    var validationError: String?
    var hasAttemptedSubmit: Bool = false

    var canSubmit: Bool {
        !isValidating
        && !urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && parsedURL != nil
        && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var parsedURL: URL? {
        parsedHTTPURL(from: urlText)
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
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
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

        validationError = nil
        isValidating = false
        testStatus = .idle
        return ServerProfile(
            name: resolvedName(for: url),
            url: url,
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func resolvedName(for url: URL) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return url.host ?? "Hermes"
    }
}
