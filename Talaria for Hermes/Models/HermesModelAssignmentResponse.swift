import Foundation

struct HermesModelAssignmentResponse: Decodable, Sendable {
    let ok: Bool
    let provider: String?
    let model: String?
    let baseURL: String?
    let confirmRequired: Bool?
    let confirmMessage: String?

    var dashboardModel: HermesDashboardModel? {
        guard let model, !model.isEmpty else { return nil }
        return HermesDashboardModel(
            modelID: model,
            provider: provider,
            baseURL: baseURL,
            contextLength: nil
        )
    }
}
