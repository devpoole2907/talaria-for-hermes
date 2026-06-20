import SwiftUI

struct ModelProviderModelsView: View {
    @Environment(AppModel.self) private var appModel

    let group: ModelProviderGroup
    var onFinish: () -> Void

    @State private var pendingModelID: String?
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                ForEach(group.models) { model in
                    Button(action: { select(model) }) {
                        ModelSelectionRow(
                            title: model.id,
                            subtitle: model.subtitle,
                            selected: model.id == appModel.modelStore.displayModelID,
                            isLoading: pendingModelID == model.id && appModel.modelStore.switching
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(appModel.modelStore.switching)
                }
            } footer: {
                Text(group.provider == nil ? "Provider remains automatic for these models." : "Provider: \(group.provider ?? group.name)")
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func select(_ model: ModelProviderModel) {
        if model.id == appModel.modelStore.displayModelID {
            onFinish()
            return
        }

        pendingModelID = model.id
        errorMessage = nil
        Task {
            let switched = await appModel.switchModel(modelID: model.id, provider: group.provider)
            pendingModelID = nil
            if switched {
                onFinish()
            } else {
                errorMessage = appModel.modelStore.adminError?.errorDescription
            }
        }
    }
}
