import SwiftUI

struct TurnView: View {
    let turn: ChatTurn
    let isWorking: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            UserMessageView(turn: turn)

            AssistantMessageView(turn: turn)

            if isWorking && turn.hasLiveContent == false {
                ThinkingIndicatorView()
            }
        }
    }
}
