import Foundation
import Observation

/// Which server this copy of the app talks to, and the token it talks with.
///
/// The address is not a secret and lives in UserDefaults, which means it
/// survives a reinstall in an iCloud backup and the person does not have to
/// type it again. The token is a credential and lives in the Keychain. Keeping
/// them apart is deliberate rather than tidy: it means a device backup carries
/// the convenience without carrying the ability to publish.
@MainActor
@Observable
final class AccountStore {
    private static let service = "io.bytestud.broadside"
    private static let tokenKey = "api-token"
    private static let serverKey = "server-url"

    /// The server's base address, with no trailing slash.
    private(set) var serverURL: URL?

    /// Whether there is a token on file. The token itself is deliberately not
    /// published as a property, so nothing in the view layer can put it on
    /// screen or into a log by accident.
    private(set) var isSignedIn: Bool = false

    init() {
        if let stored = UserDefaults.standard.string(forKey: Self.serverKey) {
            serverURL = URL(string: stored)
        }
        isSignedIn = serverURL != nil && Keychain.get(Self.tokenKey, service: Self.service) != nil
    }

    /// A client for the current account, or nil when there is not one yet.
    var client: BroadsideClient? {
        guard let serverURL, let token = Keychain.get(Self.tokenKey, service: Self.service) else {
            return nil
        }
        return BroadsideClient(baseURL: serverURL, token: token)
    }

    /// Checks the address and token against the server before keeping them.
    ///
    /// Storing first and discovering later that the token was mistyped leaves
    /// the app in a state where every screen is an error and the only way out
    /// is signing out, which reads as the app being broken rather than as the
    /// token being wrong.
    func signIn(serverURL rawURL: String, token: String) async throws {
        let url = try Self.normalize(rawURL)
        let candidate = BroadsideClient(baseURL: url, token: token)

        // The cheapest authenticated call there is. Anything that comes back
        // without an error means the address resolves, the server is Broadside,
        // and the token is good.
        _ = try await candidate.posts(limit: 1)

        try Keychain.set(token, for: Self.tokenKey, service: Self.service)
        UserDefaults.standard.set(url.absoluteString, forKey: Self.serverKey)

        serverURL = url
        isSignedIn = true
    }

    func signOut() {
        Keychain.remove(Self.tokenKey, service: Self.service)
        UserDefaults.standard.removeObject(forKey: Self.serverKey)
        serverURL = nil
        isSignedIn = false
    }

    /// Turns what somebody typed into an address that can be requested.
    ///
    /// People type "blog.example.com", and paste "https://blog.example.com/"
    /// with the slash, and on a home network they type "192.168.1.50:5555".
    /// All three are the same intent and all three should work.
    nonisolated static func normalize(_ raw: String) throws -> URL {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw APIError.invalidServerAddress }

        while text.hasSuffix("/") { text.removeLast() }

        if !text.contains("://") {
            /*
              The scheme follows the address, because the two cases genuinely
              want different answers and guessing one for both is a trap.

              A public host defaults to https: downgrading somebody's blog to
              plain HTTP because they left the scheme off would be a bad thing
              to do quietly, and App Transport Security refuses it anyway.

              A host on the local network defaults to http, because that is
              what is actually running there. Broadside on a Raspberry Pi or a
              NAS is reached over plain HTTP by nearly everybody who runs it,
              and this screen tells them to type "192.168.1.50:5555". Assuming
              https for that address means the advice on screen leads straight
              to a TLS error.
            */
            text = (Self.isLocalAddress(hostPart(of: text)) ? "http://" : "https://") + text
        }

        guard let url = URL(string: text), let host = url.host(), !host.isEmpty else {
            throw APIError.invalidServerAddress
        }

        return url
    }

    /// The host out of something with no scheme yet, such as
    /// "192.168.1.50:5555/blog".
    nonisolated private static func hostPart(of text: String) -> String {
        var host = text
        if let slash = host.firstIndex(of: "/") { host = String(host[..<slash]) }

        // An IPv6 literal is bracketed, and its own colons are not port
        // separators.
        if host.hasPrefix("["), let end = host.firstIndex(of: "]") {
            return String(host[host.index(after: host.startIndex)..<end])
        }
        if let colon = host.lastIndex(of: ":") { host = String(host[..<colon]) }
        return host
    }

    /// Whether this is an address App Transport Security lets the app reach
    /// over plain HTTP.
    ///
    /// The list mirrors what `NSAllowsLocalNetworking` permits, so the scheme
    /// this picks and the scheme the system will allow are the same decision
    /// rather than two that can disagree.
    nonisolated static func isLocalAddress(_ host: String) -> Bool {
        let host = host.lowercased()

        if host == "localhost" || host.hasSuffix(".local") { return true }

        // An unqualified name, such as a machine called "nas". Reached on a
        // local network by definition, since there is no public DNS for it.
        if !host.contains(".") && !host.contains(":") { return true }

        if host == "::1" { return true }
        if host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd") { return true }

        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }

        switch (parts[0], parts[1]) {
        case (127, _): return true                       // loopback
        case (10, _): return true                        // private
        case (192, 168): return true                     // private
        case (172, 16...31): return true                 // private
        case (169, 254): return true                     // link local
        default: return false
        }
    }
}
