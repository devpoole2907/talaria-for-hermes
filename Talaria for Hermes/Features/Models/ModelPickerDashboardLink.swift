import SwiftUI

struct ModelPickerDashboardLink: View {
    let dashboardURL: URL?

    var body: some View {
        if let dashboardURL {
            Link(destination: dashboardURL) {
                Label("Open Hermes Dashboard", systemImage: "safari")
            }
        } else {
            Label("Hermes Dashboard", systemImage: "slider.horizontal.3")
                .foregroundStyle(.secondary)
        }
    }
}
