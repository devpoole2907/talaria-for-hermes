import SwiftUI
import Textual

struct MarkdownText: View {
    let source: String

    var body: some View {
        StructuredText(markdown: HermesMarkdownRenderer.prepare(source))
            .font(.body)
            .textual.structuredTextStyle(.gitHub)
            .textual.textSelection(.enabled)
            .textual.overflowMode(.wrap)
    }
}
