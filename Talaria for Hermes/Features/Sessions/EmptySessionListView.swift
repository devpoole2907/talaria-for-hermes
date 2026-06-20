import SwiftUI

struct EmptySessionListView: View {
    var onCreate: () -> Void

    var body: some View {
        ContentUnavailableViews.noSessions(onCreate: onCreate)
    }
}
