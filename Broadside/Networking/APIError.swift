import Foundation

/// What can go wrong talking to a Broadside server.
///
/// Every case here carries a message somebody can act on. A self-hosted app
/// fails in ways a hosted one does not — the server is off, the address moved,
/// the token was revoked, the reverse proxy in front has its own body size
/// limit — and "Something went wrong" leaves the person with no idea which of
/// those it was or which one of them they can fix.
enum APIError: LocalizedError, Equatable {
    case invalidServerAddress
    case notSignedIn
    case unauthorized
    case notFound
    case tooLarge

    /// The server answered, and does not have this endpoint.
    ///
    /// Worth its own case rather than folding into `notFound`, because it means
    /// something entirely different and has a different fix. Broadside is
    /// self-hosted, so the app on somebody's phone updates from the App Store
    /// while the binary on their server updates when they get round to it. An
    /// app newer than the server it talks to is the normal state of things, not
    /// an error, and telling them "not found" sends them looking for a post.
    case notSupported(feature: String)
    case server(status: Int, message: String)
    case transport(String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .invalidServerAddress:
            "That does not look like a web address."

        case .notSignedIn:
            "This app is not connected to a server yet."

        case .unauthorized:
            "That token was refused. It may have been revoked on the server."

        case .notFound:
            "The server does not have that post."

        case let .notSupported(feature):
            "This server is running a version of Broadside without \(feature)."

        case .tooLarge:
            "The server refused that file for being too large."

        case let .server(status, message):
            message.isEmpty ? "The server answered with an error (\(status))." : message

        case let .transport(detail):
            detail

        case .malformedResponse:
            "The server sent something this app could not read. Check that the address points at Broadside."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .unauthorized:
            "Create a new token on the API tab of your site and sign in again."
        case .notSupported:
            "Update Broadside on your server, then try again. Everything else in the app keeps working in the meantime."

        case .tooLarge:
            "Raise the upload limit in Site Settings. If a reverse proxy sits in front of Broadside, check its own limit as well."
        case .transport:
            "Check that the server is running and reachable from this device."
        default:
            nil
        }
    }
}
