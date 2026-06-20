import SwiftUI

struct ProfileEditView: View {
    @Environment(\.dismiss) private var dismiss
    var profile: ServerProfile
    var onSave: (ServerProfile) -> Void

    @State private var name: String = ""
    @State private var urlText: String = ""
    @State private var apiKey: String = ""
    @State private var adminURLText: String = ""
    @State private var adminUsername: String = ""
    @State private var adminPassword: String = ""
    @State private var testStatus: SetupModel.TestStatus = .idle

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Name", text: $name)
                    TextField("URL", text: $urlText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                Section("Authentication") {
                    SecureField("API Key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Dashboard") {
                    TextField("URL", text: $adminURLText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Username", text: $adminUsername)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $adminPassword)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    Button("Test Connection", action: runTest)
                        .disabled(parsedURL == nil || apiKey.isEmpty)
                    SetupTestStatusRow(status: testStatus)
                }
            }
            .navigationTitle("Edit Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: { dismiss() })
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save", action: save)
                        .disabled(name.isEmpty || parsedURL == nil || apiKey.isEmpty || !adminURLIsValid)
                        .bold()
                }
            }
            .onAppear {
                name = profile.name
                urlText = profile.url.absoluteString
                apiKey = profile.apiKey
                adminURLText = profile.adminURL?.absoluteString ?? ""
                adminUsername = profile.adminUsername ?? ""
                adminPassword = profile.adminPassword ?? ""
            }
        }
    }

    private var parsedURL: URL? {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme == "http" || url.scheme == "https"
        else { return nil }
        return url
    }

    private var parsedAdminURL: URL? {
        let trimmed = adminURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let url = URL(string: trimmed),
              url.scheme == "http" || url.scheme == "https"
        else { return nil }
        return url
    }

    private var adminURLIsValid: Bool {
        adminURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || parsedAdminURL != nil
    }

    private func runTest() {
        guard let url = parsedURL else { return }
        testStatus = .testing
        let client = HermesClient(baseURL: url, apiKey: apiKey, sessionKey: "talaria:setup-test")
        Task {
            do {
                let health = try await client.health()
                testStatus = .ok(version: health.version ?? "?", platform: health.platform)
            } catch {
                testStatus = .failed(message: HermesError(error).errorDescription ?? "Couldn't reach the server.")
            }
        }
    }

    private func save() {
        guard let url = parsedURL else { return }
        let updated = ServerProfile(
            id: profile.id,
            name: name,
            url: url,
            apiKey: apiKey,
            adminURL: parsedAdminURL,
            adminUsername: adminUsername.isEmpty ? nil : adminUsername,
            adminPassword: adminPassword.isEmpty ? nil : adminPassword
        )
        onSave(updated)
        dismiss()
    }
}
