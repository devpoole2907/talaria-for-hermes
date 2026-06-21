import Foundation

/// Response from the Talaria plugin's `POST /api/plugins/talaria/attachments`.
/// `storedPath` is the absolute path on the Hermes host that the agent's
/// `read_file` / `web_extract` tools can read.
struct TalariaAttachment: Decodable, Sendable, Equatable {
    let id: String
    let filename: String
    let storedPath: String
    /// Path relative to HERMES_HOME (e.g. `talaria_uploads/<id>/<name>`). Used to
    /// build a mount-independent reference for the agent: the plugin may run in a
    /// container with a different absolute path than the agent's host tools, so
    /// `storedPath` can be unresolvable for the agent while this always works.
    let relativePath: String?
    let size: Int
    let contentType: String?

    /// The path to hand the agent: `~/.hermes/<relativePath>` when available
    /// (resolves regardless of container/host mount), else the absolute path.
    var agentReadablePath: String {
        if let relativePath, !relativePath.isEmpty {
            return "~/.hermes/\(relativePath)"
        }
        return storedPath
    }
}
