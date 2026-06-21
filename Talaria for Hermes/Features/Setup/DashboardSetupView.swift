import SwiftUI

struct DashboardSetupView: View {
    @Environment(\.dismiss) private var dismiss
    var onComplete: (ServerProfile) throws -> Void

    @State private var model: DashboardSetupModel
    @State private var saveTask: Task<Void, Never>?

    init(profile: ServerProfile, onComplete: @escaping (ServerProfile) throws -> Void) {
        self.onComplete = onComplete
        self._model = State(initialValue: DashboardSetupModel(profile: profile))
    }

    var body: some View {
        NavigationStack {
            setupForm
                .modalFormStyle(
                    title: "Hermes Dashboard",
                    primaryTitle: "Connect",
                    isPrimaryDisabled: !model.canSubmit,
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
                Text("Connect Talaria to Hermes Dashboard.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section {
                ServerURLField(url: $model.urlText, title: "Dashboard address")
            } header: {
                Text("Dashboard")
            } footer: {
                if model.hasAttemptedSubmit && model.urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label("Dashboard address is required.", systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.footnote)
                } else {
                    Text("Enter the full dashboard address, including port if needed. Example: http://forge.local:9119.")
                }
            }

            Section {
                TextField("Username", text: $model.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                SecureField("Password", text: $model.password)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Authentication")
            } footer: {
                Text("Leave blank if your dashboard does not require a login.")
            }

            ValidationErrorSection(error: model.validationError)

            if model.isValidating {
                Section {
                    HStack {
                        ProgressView()
                        Text("Checking dashboard…")
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
            do {
                try onComplete(profile)
                dismiss()
            } catch {
                model.validationError = error.localizedDescription
            }
        }
    }
}
