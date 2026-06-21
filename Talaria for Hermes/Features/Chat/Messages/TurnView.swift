import SwiftUI

struct TurnView: View {
    let turn: ChatTurn
    let isWorking: Bool
    var isReconnecting: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            UserMessageView(turn: turn)

            AssistantMessageView(turn: turn)

            if isReconnecting {
                ReconnectingIndicatorView()
            } else if isWorking && turn.hasLiveContent == false {
                ThinkingIndicatorView()
            }
        }
    }
}
