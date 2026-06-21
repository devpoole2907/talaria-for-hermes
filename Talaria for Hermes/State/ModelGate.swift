import Foundation

/// App-wide serializer for the *kickoff* of a chat turn.
///
/// Hermes has a single global model that each turn reads at run start, then binds
/// for the whole run — verified live: changing the global mid-run does not affect
/// the in-flight run, even across multi-step tool loops. So the only unsafe window
/// is between "set the global to this session's model" and "the run has started".
/// Concurrent chats (multi-agent workflows) could otherwise clobber each other's
/// global in that gap and run the wrong model.
///
/// This gate makes that gap mutually exclusive across all chats: a turn acquires
/// it before setting the model and releases it the instant its run starts (first
/// stream event). The slow part — generation — runs *without* the gate, so many
/// chats still generate concurrently; they only queue for the sub-second kickoff.
///
/// FIFO so turns kick off in the order they were sent. `@MainActor` because all
/// chat state lives there; the lock is only ever held across `await`s briefly.
@MainActor
final class ModelGate {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Waits until the gate is free and takes it. Pair every `acquire()` with
    /// exactly one `release()` (use the idempotent helper in `ChatStore`).
    func acquire() async {
        if !isHeld {
            isHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Hands the gate to the next waiter, or frees it if none are queued.
    func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            let next = waiters.removeFirst()
            next.resume()
        }
    }
}
