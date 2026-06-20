import SwiftUI

struct ValidationErrorSection: View {
    let error: String?

    var body: some View {
        if let error {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)

                    Text(error)
                        .foregroundStyle(.primary)
                        .font(.subheadline)
                }
                .padding(.vertical, 2)
            }
        }
    }
}
