import SwiftUI

struct ModelPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var appModel

    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Current") {
                    LabeledContent("Model", value: appModel.modelStore.displayModelID)
                    if let provider = currentProvider {
                        LabeledContent("Provider", value: provider)
                    }
                    if let contextLength = appModel.modelStore.currentModel?.contextLength, contextLength > 0 {
                        LabeledContent("Context", value: contextLength.formatted())
                    }
                }

                Section("Providers") {
                    ForEach(providerGroups) { group in
                        NavigationLink(value: group) {
                            ModelProviderRow(
                                group: group,
                                selectedModelID: appModel.modelStore.displayModelID
                            )
                        }
                    }
                }

                Section {
                    ModelPickerDashboardLink(dashboardURL: appModel.activeProfile.dashboardURL)
                } footer: {
                    Text("Providers are configured in Hermes Dashboard.")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Model")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: ModelProviderGroup.self) { group in
                ModelProviderModelsView(group: group, onFinish: { dismiss() })
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: { dismiss() }).bold()
                }
            }
            .task {
                await refresh()
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var currentProvider: String? {
        let trimmed = appModel.modelStore.currentModel?.provider?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        if trimmed.lowercased() == "auto" {
            return "Automatic"
        }
        return trimmed
    }

    private var providerGroups: [ModelProviderGroup] {
        ModelProviderCatalog.groups(
            current: appModel.modelStore.currentModel,
            recentModelIDs: appModel.preferences.recentModelIDs(for: appModel.activeProfile.id),
            modelCatalog: appModel.modelStore.modelCatalog,
            config: appModel.modelStore.dashboardConfig
        )
    }

    private func refresh() async {
        await appModel.modelStore.refresh()
        errorMessage = appModel.modelStore.adminError?.errorDescription
            ?? appModel.modelStore.configError?.errorDescription
    }
}
