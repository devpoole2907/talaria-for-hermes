import SwiftUI

struct ServerURLField: View {
    @Binding var url: String
    var title: String = "Server address"

    var body: some View {
        TextField(title, text: $url)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .textContentType(.URL)
            .autocorrectionDisabled()
    }
}
