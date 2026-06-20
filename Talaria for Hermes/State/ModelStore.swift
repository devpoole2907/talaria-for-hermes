import Foundation
import Observation

@MainActor
@Observable
final class ModelStore {
    var currentModel: HermesDashboardModel?
    var modelCatalog: HermesModelCatalogResponse?
    var dashboardConfig: HermesDashboardConfigResponse?
    var loading: Bool = false
    var switching: Bool = false
    var lastError: HermesError?
    var adminError: HermesError?
    var configError: HermesError?

    private let client: HermesClient

    init(client: HermesClient) {
        self.client = client
    }

    func refresh() async {
        loading = true
        defer { loading = false }
        lastError = nil
        await refreshCurrentModel()
        await refreshDashboardConfiguration()
    }

    func refreshCurrentModel() async {
        do {
            currentModel = try await client.dashboardCurrentModel()
            adminError = nil
        } catch {
            adminError = HermesError(error)
        }
    }

    func refreshDashboardConfiguration() async {
        configError = nil

        do {
            modelCatalog = try await client.dashboardModelCatalog()
        } catch HermesError.notFound {
            modelCatalog = nil
        } catch {
            configError = HermesError(error)
        }

        do {
            dashboardConfig = try await client.dashboardConfig()
        } catch HermesError.notFound {
            dashboardConfig = nil
        } catch {
            if configError == nil {
                configError = HermesError(error)
            }
        }
    }

    func switchModel(modelID: String, provider: String?) async -> Bool {
        let trimmedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedProvider = provider?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModelID.isEmpty else { return false }

        switching = true
        defer { switching = false }
        do {
            let response = try await client.switchDashboardModel(
                modelID: trimmedModelID,
                provider: trimmedProvider?.isEmpty == true ? nil : trimmedProvider
            )
            guard response.ok else {
                adminError = HermesError.httpStatus(409, response.confirmMessage)
                return false
            }
            if let dashboardModel = response.dashboardModel {
                currentModel = dashboardModel
            }
            adminError = nil
            return true
        } catch {
            adminError = HermesError(error)
            return false
        }
    }

    var displayModelID: String {
        currentModel?.modelID ?? "hermes-agent"
    }
}
