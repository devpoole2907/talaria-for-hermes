import SwiftUI

struct SetupView: View {
    @Environment(\.dismiss) private var dismiss
    var onComplete: (ServerProfile) -> Void

    @State private var model = SetupModel()
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            setupForm
                .modalFormStyle(
                    title: "Add Server",
                    primaryTitle: "Connect",
                    isPrimaryDisabled: model.isValidating,
                    isSaving: model.isValidating
                ) {
                    connect()
                }
                .onDisappear {
                    saveTask?.cancel()
                }
        }
    }

    private var setupForm: some View {
        Form {
            Section {
                Text("Connect Talaria to your Hermes API server.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section {
                ServerURLField(url: $model.urlText)

                TextField("Display Name (optional)", text: $model.name)
                    .textContentType(.organizationName)
            } header: {
                Text("Server")
            } footer: {
                if model.hasAttemptedSubmit && model.urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label("Server address is required.", systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.footnote)
                } else {
                    Text("Enter the full Hermes API address, including port if needed. Example: http://forge.local:8642.")
                }
            }

            Section {
                SecureField("API Key", text: $model.apiKey)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Authentication")
            } footer: {
                if model.hasAttemptedSubmit && model.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label("API key is required.", systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }

            Section {
                ServerURLField(url: $model.adminURLText, title: "Dashboard address (optional)")

                TextField("Username", text: $model.adminUsername)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                SecureField("Password", text: $model.adminPassword)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Dashboard")
            } footer: {
                if model.hasAttemptedSubmit && !model.adminURLIsValid {
                    Label("Dashboard address must be a valid http(s) URL.", systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.footnote)
                } else {
                    Text("Optional. Add dashboard credentials to enable model switching and server settings from Talaria.")
                }
            }

            ValidationErrorSection(error: model.validationError)

            if model.isValidating {
                Section {
                    HStack {
                        ProgressView()
                        Text("Checking connection…")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func connect() {
        saveTask?.cancel()
        saveTask = Task {
            guard let profile = await model.validateAndBuild(), !Task.isCancelled else { return }
            onComplete(profile)
            dismiss()
        }
    }
}
