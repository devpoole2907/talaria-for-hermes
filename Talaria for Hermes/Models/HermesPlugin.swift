import Foundation

/// Central definition of the Talaria plugin's HTTP surface on the Hermes
/// dashboard. All admin + attachment calls route through these paths so the app
/// depends on the plugin's stable contract, not raw (un-versioned) dashboard
/// routes. Keeping the prefix in one place means a rename is a one-line change.
enum HermesPlugin {
    /// Mount prefix on the dashboard (port 9119), under the admin cookie auth.
    static let base = "/api/plugins/talaria"

    /// A path directly under the plugin (e.g. `attachments`, `status`).
    static func path(_ suffix: String) -> String {
        "\(base)/\(suffix)"
    }

    /// A path under the admin facade (e.g. `model/info`, `model/set`).
    static func adminPath(_ suffix: String) -> String {
        "\(base)/admin/\(suffix)"
    }
}
