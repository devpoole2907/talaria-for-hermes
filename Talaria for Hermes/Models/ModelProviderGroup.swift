import Foundation

struct ModelProviderGroup: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let provider: String?
    let subtitle: String
    let models: [ModelProviderModel]

    var modelCountText: String {
        models.count.formatted()
    }

    var modelCountAccessibilityText: String {
        models.count == 1 ? "1 model" : "\(models.count.formatted()) models"
    }
}
