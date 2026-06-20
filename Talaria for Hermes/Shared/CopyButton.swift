import SwiftUI

struct CopyButton: View {
    let text: String
    @State private var copyTrigger: Int = 0

    var body: some View {
        Button("Copy", systemImage: "doc.on.doc", action: copy)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .frame(minWidth: TapTarget.minimum, minHeight: TapTarget.minimum)
            .sensoryFeedback(.success, trigger: copyTrigger)
    }

    private func copy() {
        UIPasteboard.general.string = text
        copyTrigger += 1
    }
}
