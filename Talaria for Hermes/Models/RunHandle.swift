import Foundation

struct RunHandle: Codable, Sendable {
    let runId: String
    let status: String?
    /// The name of the most recent event emitted by this run (e.g. "tool.completed",
    /// "message.delta"). The JSON decoder uses `.convertFromSnakeCase` so this maps
    /// from the server's `last_event` key automatically. Used to surface a live
    /// heartbeat during recovery when the /events stream can't be re-attached.
    let lastEvent: String?
    /// Unix seconds when this run last made progress (the server advances this on every
    /// event). Maps from `updated_at`. Nil when the field is absent (older server builds
    /// or a completed run that stopped emitting updates).
    let updatedAt: Double?
}
