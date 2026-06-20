import SwiftUI

struct ProminentBottomButton: View {
    let title: LocalizedStringKey
    var systemImage: String?
    var isLoading = false
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .controlSize(.large)
        .fontWeight(.medium)
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.capsule)
        .buttonSizing(.flexible)
        .disabled(isDisabled || isLoading)
        .scenePadding(.horizontal)
    }
}

extension View {
    func prominentBottomButton(
        _ title: LocalizedStringKey,
        systemImage: String? = nil,
        isLoading: Bool = false,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        safeAreaInset(edge: .bottom) {
            ProminentBottomButton(
                title: title,
                systemImage: systemImage,
                isLoading: isLoading,
                isDisabled: isDisabled,
                action: action
            )
        }
    }
}
