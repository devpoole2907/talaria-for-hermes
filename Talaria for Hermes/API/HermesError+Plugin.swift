import Foundation

extension HermesError {
    /// True when a failure against the Talaria plugin's endpoints looks like the
    /// plugin isn't installed (404 — the route is missing) or is too old for this
    /// app (501 — the plugin returns "handler unavailable"). Lets the UI show a
    /// precise "install/update the plugin" hint instead of a generic error.
    var indicatesPluginUnavailable: Bool {
        switch self {
        case .notFound:
            return true
        case .httpStatus(let code, _):
            return code == 501
        default:
            return false
        }
    }

    /// A user-facing message tuned for the plugin admin surface: distinguishes a
    /// missing/outdated plugin and bad credentials from generic failures.
    var pluginGuidanceDescription: String {
        if indicatesPluginUnavailable {
            return "The Talaria plugin isn't installed or is outdated on your Hermes server. "
                + "Install or update talaria-plugin and restart the gateway."
        }
        if case .unauthorized = self {
            return "The Hermes Dashboard credentials are missing or incorrect. "
                + "Check the admin username and password in your server profile."
        }
        return errorDescription ?? "Couldn't reach the Talaria plugin."
    }
}
