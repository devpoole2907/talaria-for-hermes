import SwiftUI

struct ModelPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var appModel

    let selectedModelID: String
    var onSelectModel: (String, String?) async -> Bool

    @State private var displayedModelID: String
    @State private var errorMessage: String?

    init(
        selectedModelID: String,
        onSelectModel: @escaping (String, String?) async -> Bool
    ) {
        self.selectedModelID = selectedModelID
        self.onSelectModel = onSelectModel
        self._displayedModelID = State(initialValue: selectedModelID)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Current") {
                    LabeledContent("Model", value: displayedModelID)
                    if let provider = currentProvider {
                        LabeledContent("Provider", value: provider)
                    }
                    if let contextLength = selectedContextLength, contextLength > 0 {
                        LabeledContent("Context", value: contextLength.formatted())
                    }
                }

                if appModel.activeProfile.isDashboardConfigured {
                    Section("Providers") {
                        ForEach(providerGroups) { group in
                            NavigationLink(value: group) {
                                ModelProviderRow(
                                    group: group,
                                    selectedModelID: displayedModelID
                                )
                            }
                        }
                    }
                } else {
                    Section("Providers") {
                        Label("Hermes Dashboard is not configured.", systemImage: "slider.horizontal.3")
                            .foregroundStyle(.secondary)
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
                ModelProviderModelsView(
                    group: group,
                    selectedModelID: displayedModelID,
                    onSelectModel: selectModel,
                    onFinish: { dismiss() }
                )
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: { dismiss() }).bold()
                }
            }
            .task {
                await refresh()
            }
            .onChange(of: selectedModelID) { _, newValue in
                displayedModelID = newValue
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var currentProvider: String? {
        guard let group = providerGroups.first(where: { group in
            group.models.contains { $0.id == displayedModelID }
        }),
              group.provider != nil
        else {
            return nil
        }
        return group.name
    }

    private var selectedContextLength: Int? {
        guard appModel.modelStore.currentModel?.modelID == displayedModelID else { return nil }
        return appModel.modelStore.currentModel?.contextLength
    }

    private var providerGroups: [ModelProviderGroup] {
        let current = HermesDashboardModel(
            modelID: displayedModelID,
            provider: nil,
            baseURL: nil,
            contextLength: selectedContextLength
        )
        return ModelProviderCatalog.groups(
            current: current,
            recentModelIDs: appModel.preferences.recentModelIDs(for: appModel.activeProfile.id),
            modelCatalog: appModel.modelStore.modelCatalog,
            config: appModel.modelStore.dashboardConfig
        )
    }

    private func refresh() async {
        guard appModel.activeProfile.isDashboardConfigured else {
            errorMessage = nil
            return
        }
        await appModel.modelStore.refresh()
        // Use plugin-aware guidance so a missing/outdated Talaria plugin reads as
        // "install/update the plugin" rather than a bare "not found".
        errorMessage = appModel.modelStore.adminError?.pluginGuidanceDescription
            ?? appModel.modelStore.configError?.pluginGuidanceDescription
    }

    private func selectModel(modelID: String, provider: String?) async -> Bool {
        let switched = await onSelectModel(modelID, provider)
        if switched {
            displayedModelID = modelID
        }
        return switched
    }
}
