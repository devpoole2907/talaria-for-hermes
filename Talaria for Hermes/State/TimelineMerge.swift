import Foundation

// MARK: - TimelineMerge

/// Pure merge function for reconciling a server-authoritative message list
/// with the locally persisted timeline (which may contain a partial / incomplete
/// assistant reply for the last turn that never made it back to the server).
///
/// Merge rule:
/// - Group each list into turns: a turn = a user message + all following non-user messages.
/// - Align turns by index and verify the user-message content matches (trim-compare),
///   so a server reply is never misattributed to a different turn.
/// - For each aligned turn:
///   • Server has an assistant reply → take the server turn in full (server truth).
///   • Server has NO assistant reply → keep the server user message + any local
///     partial assistant/tool messages for that turn (preserve the streamed partial).
/// - Append any local-only trailing turns not yet present on the server (offline sends).
func mergeServer(_ server: [TimelineMessage], withLocal local: [TimelineMessage]) -> [TimelineMessage] {
    let serverTurns = groupIntoTurns(server)
    let localTurns  = groupIntoTurns(local)

    var result: [TimelineMessage] = []

    for (index, serverTurn) in serverTurns.enumerated() {
        // Find the matching local turn by order index, verifying user-message content
        // so a mismatch (e.g. the user deleted and re-sent) never carries a stale partial.
        let localTurn = index < localTurns.count ? localTurns[index] : nil
        let contentMatches: Bool = {
            guard let local = localTurn else { return false }
            let s = serverTurn.userMessage.message.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let l = local.userMessage.message.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return s == l
        }()

        let serverHasAssistantReply = serverTurn.nonUserMessages.contains {
            $0.message.role == "assistant"
        }

        if serverHasAssistantReply || !contentMatches || localTurn == nil {
            // Server truth: use the full server turn.
            result.append(serverTurn.userMessage)
            result.append(contentsOf: serverTurn.nonUserMessages)
        } else {
            // Server has the user message but no assistant reply yet. Keep the server
            // user message (authoritative id/timestamp) and carry the local partial.
            result.append(serverTurn.userMessage)
            // Include local non-user messages, collapsing any run of incomplete
            // assistant partials to just the last (longest) one — older builds wrote a
            // fresh partial row every streaming tick, leaving N cumulative duplicates;
            // this heals that on the next merge and is correct anyway (one partial reply).
            result.append(contentsOf: collapsedPartials(localTurn!.nonUserMessages))
        }
    }

    // Append local-only turns that have no server counterpart (e.g. offline sends).
    let localOnlyTurns = localTurns.dropFirst(serverTurns.count)
    for turn in localOnlyTurns {
        result.append(turn.userMessage)
        result.append(contentsOf: turn.nonUserMessages)
    }

    return result
}

/// Collapses a turn's local non-user messages so multiple incomplete assistant
/// partials (from older per-tick persistence) become a single one — the last, which
/// is the longest/most-recent snapshot. Tool messages and any completed assistant
/// message are preserved as-is.
private func collapsedPartials(_ messages: [TimelineMessage]) -> [TimelineMessage] {
    let incompleteAssistants = messages.filter {
        $0.message.role == "assistant" && $0.message.finishReason == nil
    }
    guard incompleteAssistants.count > 1 else { return messages }

    var result: [TimelineMessage] = []
    var keptPartial = false
    for message in messages {
        let isIncompleteAssistant = message.message.role == "assistant" && message.message.finishReason == nil
        if isIncompleteAssistant {
            // Keep only the last incomplete partial; drop the earlier cumulative ones.
            if message.localID == incompleteAssistants.last?.localID, !keptPartial {
                result.append(message)
                keptPartial = true
            }
        } else {
            result.append(message)
        }
    }
    return result
}

// MARK: - Turn grouping

private struct Turn {
    let userMessage: TimelineMessage
    let nonUserMessages: [TimelineMessage]
}

/// Groups a flat timeline into turns. Mirrors ChatStore.rebuildTurns: a turn
/// starts at each "user" role message and includes all following non-user messages.
private func groupIntoTurns(_ timeline: [TimelineMessage]) -> [Turn] {
    var turns: [Turn] = []
    var i = 0
    while i < timeline.count {
        guard timeline[i].message.role == "user" else { i += 1; continue }
        let userMsg = timeline[i]
        var nonUser: [TimelineMessage] = []
        var j = i + 1
        while j < timeline.count, timeline[j].message.role != "user" {
            nonUser.append(timeline[j])
            j += 1
        }
        turns.append(Turn(userMessage: userMsg, nonUserMessages: nonUser))
        i = j
    }
    return turns
}
