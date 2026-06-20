import SwiftUI

struct AddProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onAdded: (ServerProfile) -> Void

    var body: some View {
        SetupView { profile in
            onAdded(profile)
            dismiss()
        }
    }
}
