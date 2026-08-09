import Testing
import Foundation
@testable import Broadside

/// Turning what somebody typed into an address that can be requested.
///
/// This is the first thing the app does and the first thing that can go wrong,
/// and it is worth more tests than it looks because the failure is somebody
/// concluding the app does not work with their server.
struct AccountAddressTests {

    /// A public host gets https, because downgrading somebody's blog to plain
    /// HTTP over a missing scheme would be a bad thing to do quietly, and the
    /// system refuses it in any case.
    @Test(arguments: [
        "blog.example.com",
        "www.thebytes.net",
        "blog.example.com/",
    ])
    func defaultsPublicHostsToHTTPS(_ typed: String) throws {
        let url = try AccountStore.normalize(typed)
        #expect(url.scheme == "https")
    }

    /// A local address gets http, because that is what is actually running
    /// there. Getting this wrong sent anybody following the hint on the connect
    /// screen — "192.168.1.50:5555" — straight into a TLS error.
    @Test(arguments: [
        "192.168.1.50:5555",
        "10.0.0.4:5555",
        "172.16.5.5:5555",
        "127.0.0.1:5561",
        "localhost:5555",
        "nas:5555",
        "raspberrypi.local:5555",
    ])
    func defaultsLocalAddressesToHTTP(_ typed: String) throws {
        let url = try AccountStore.normalize(typed)
        #expect(url.scheme == "http", "\(typed) should default to http")
    }

    /// 172.16 through 172.31 is private and 172.32 is not, which is the part of
    /// the range everybody gets wrong.
    @Test func knowsWhereThe172RangeEnds() {
        #expect(AccountStore.isLocalAddress("172.16.0.1"))
        #expect(AccountStore.isLocalAddress("172.31.255.254"))
        #expect(!AccountStore.isLocalAddress("172.32.0.1"))
        #expect(!AccountStore.isLocalAddress("172.15.0.1"))
    }

    /// An explicit scheme is always obeyed. Somebody who typed https meant it,
    /// even against a machine on their own network with a certificate on it.
    @Test func neverOverridesAnExplicitScheme() throws {
        #expect(try AccountStore.normalize("https://192.168.1.50:5555").scheme == "https")
        #expect(try AccountStore.normalize("http://blog.example.com").scheme == "http")
    }

    /// Trailing slashes go, or every request path would end up doubled.
    @Test func trimsTrailingSlashes() throws {
        let url = try AccountStore.normalize("https://blog.example.com///")
        #expect(url.absoluteString == "https://blog.example.com")
    }

    @Test func rejectsNonsense() {
        #expect(throws: APIError.invalidServerAddress) {
            _ = try AccountStore.normalize("")
        }
        #expect(throws: APIError.invalidServerAddress) {
            _ = try AccountStore.normalize("   ")
        }
    }

    /// A bracketed IPv6 literal has colons of its own, and reading the last one
    /// as a port separator would mangle the host.
    @Test func handlesIPv6Literals() {
        #expect(AccountStore.isLocalAddress("::1"))
        #expect(AccountStore.isLocalAddress("fe80::1"))
        #expect(!AccountStore.isLocalAddress("2001:4860:4860::8888"))
    }
}
