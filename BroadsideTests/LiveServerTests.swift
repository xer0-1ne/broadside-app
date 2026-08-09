import Testing
import Foundation
@testable import Broadside

/// Exercises the client against a real Broadside server.
///
/// Everything else in this target is pure logic. This is the part that can only
/// be wrong in ways a unit test cannot see: whether the JSON field names match,
/// whether Go's timestamps decode, whether the multipart body is one the Go
/// handler accepts, and whether App Transport Security will even let the app
/// talk to a server on somebody's own network over plain HTTP.
///
/// It skips itself unless pointed at a server, so an ordinary test run is
/// unaffected. To point it at one, set the variables in the simulator's own
/// environment first and then run the tests:
///
///     xcrun simctl spawn booted launchctl setenv BROADSIDE_TEST_URL http://127.0.0.1:5561
///     xcrun simctl spawn booted launchctl setenv BROADSIDE_TEST_TOKEN <token>
///     xcodebuild test -project Broadside.xcodeproj -scheme Broadside \
///       -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
///
/// The two `setenv` lines are the whole reason this comment exists. `xcodebuild`
/// does not pass the shell's environment through to a process running in the
/// simulator, so `BROADSIDE_TEST_URL=… xcodebuild test` leaves these unset;
/// neither does passing them as `TEST_RUNNER_`-prefixed build settings, whatever
/// the documentation implies. Both of those silently skip everything below and
/// report a green run that checked nothing, which is worse than a red one.
///
/// The suite-level `.enabled(if:)` is there to make that failure mode visible:
/// an unconfigured run says "skipped" against every test rather than "passed".
///
/// The credentials come from the environment rather than the repository for the
/// obvious reason.

/// Where the server details come from.
///
/// Outside the suite because the suite's own trait refers to it, and a type
/// cannot be used in an attribute attached to itself.
enum LiveServer {
    static var client: BroadsideClient? {
        let environment = ProcessInfo.processInfo.environment
        guard let raw = environment["BROADSIDE_TEST_URL"],
              let token = environment["BROADSIDE_TEST_TOKEN"],
              let url = try? AccountStore.normalize(raw)
        else { return nil }

        return BroadsideClient(baseURL: url, token: token)
    }

    /// Whether there is a server to talk to. Used as a suite-level trait rather
    /// than a guard inside each test, so an unconfigured run reports these as
    /// skipped instead of as passing without having checked anything.
    static var isConfigured: Bool { client != nil }
}

/// `.serialized` because these share one server and several of them change its
/// state. Swift Testing runs a suite in parallel by default, and settings tests
/// that each read the configuration, change it, and put it back will overwrite
/// one another's restore step if allowed to interleave. The failures that
/// produces look like product bugs and are not.
@Suite(.serialized, .enabled(if: LiveServer.isConfigured, "no server configured"))
struct LiveServerTests {

    /// Listing, and the timestamp handling that every other call depends on.
    @Test func listsPosts() async throws {
        let client = try #require(LiveServer.client)

        let page = try await client.posts(limit: 5)
        #expect(!page.posts.isEmpty, "the fixture site should have at least one post")

        let post = try #require(page.posts.first)
        #expect(!post.slug.isEmpty)
        #expect(!post.title.isEmpty)

        // Go writes RFC 3339 with an offset rather than a Z, and gets this
        // wrong nowhere except in a decoder that assumed UTC.
        #expect(post.published.timeIntervalSince1970 > 0)
    }

    /// The list endpoint omits bodies, so opening anything in the editor
    /// depends on this call returning one.
    @Test func fetchesABodyAndRoundTripsIt() async throws {
        let client = try #require(LiveServer.client)

        let page = try await client.posts(limit: 5)
        let summary = try #require(page.posts.first)
        #expect(summary.body.isEmpty, "the list should not carry bodies")

        let full = try await client.post(slug: summary.slug)
        #expect(!full.body.isEmpty)

        // The whole point of the Swift port. A real post off a real server has
        // to survive being parsed into blocks and written back out.
        let round = BlockDocument.serialize(BlockDocument.parse(full.body))
        #expect(round == full.body.withoutTrailingNewline, "a live post did not round trip:\n\(round)")
    }

    /// Create, update, and delete, in one test so a failure cannot leave a
    /// stray post behind on the fixture site.
    @Test func createsUpdatesAndDeletes() async throws {
        let client = try #require(LiveServer.client)

        var draft = Post(
            title: "Integration Check",
            published: Date(),
            draft: true,
            tags: ["test"],
            body: "A paragraph written by the test suite."
        )

        let created = try await client.create(PostSubmission(from: draft))
        #expect(!created.slug.isEmpty)
        #expect(created.draft)

        // Clean up even if an assertion below fails.
        defer {
            Task { try? await client.delete(slug: created.slug) }
        }

        // Round tripping a gallery through the server is the interesting case:
        // it goes out as a directive, is stored verbatim, and has to come back
        // parseable.
        draft = created
        draft.blocks = [
            Block(kind: .paragraph(text: "Now with pictures.")),
            Block(kind: .image(
                pictures: [
                    .init(src: "/uploads/2026/08/08/01-plate.png", alt: "One", caption: "First"),
                    .init(src: "/uploads/2026/08/08/02-plate.png", alt: "Two"),
                ],
                caption: "A pair"
            )),
        ]

        _ = try await client.update(slug: created.slug, with: PostSubmission(from: draft))

        let reloaded = try await client.post(slug: created.slug)
        #expect(reloaded.body.contains(":::gallery"))
        #expect(
            reloaded.body.withoutTrailingNewline == draft.body,
            "the server changed the body it was sent"
        )

        let blocks = BlockDocument.parse(reloaded.body)
        guard case let .image(pictures, caption) = blocks.last?.kind else {
            Issue.record("the gallery did not come back as a picture block")
            return
        }
        #expect(pictures.count == 2)
        #expect(caption == "A pair")
        #expect(pictures.first?.caption == "First")

        try await client.delete(slug: created.slug)

        await #expect(throws: APIError.notFound) {
            _ = try await client.post(slug: created.slug)
        }
    }

    /// The multipart body, built the way a large photograph would be, checked
    /// against the handler that has to accept it.
    @Test func uploadsAFile() async throws {
        let client = try #require(LiveServer.client)

        // A real PNG rather than random bytes, because the server sniffs magic
        // bytes and rejects anything whose contents disagree with its name.
        let png = Data(base64Encoded: Self.onePixelPNG)!
        let source = FileManager.default.temporaryDirectory
            .appending(path: "integration-\(UUID().uuidString).png")
        try png.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let url = try await client.upload(
            fileURL: source,
            filename: "integration.png",
            contentType: "image/png"
        )

        #expect(url.hasPrefix("/uploads/"))
        #expect(url.hasSuffix(".png"))

        // And it is really there, at the address the server handed back.
        let listed = try await client.media()
        #expect(listed.contains { $0.url == url })
    }

    /// Settings, read and written.
    ///
    /// The write is a partial update, which is the property worth checking:
    /// sending a changed title must not blank out the fields that were not
    /// sent. Everything is put back at the end.
    @Test func readsAndWritesSettings() async throws {
        let client = try #require(LiveServer.client)

        let before = try await client.settings()
        #expect(!before.title.isEmpty)

        var changed = before
        changed.title = "Renamed By The Test Suite"
        changed.theme.accent = "#123456"

        let stored = try await client.updateSettings(changed)

        #expect(stored.title == "Renamed By The Test Suite")
        #expect(stored.theme.accent == "#123456")

        // The fields that were not the point of the change came back intact,
        // which is what makes this a partial update rather than a replacement.
        #expect(stored.slogan == before.slogan)
        #expect(stored.dateFormat == before.dateFormat)
        #expect(stored.postsPerPage == before.postsPerPage)
        #expect(stored.theme.background == before.theme.background)

        // And the setup flag is pinned no matter what is sent, because turning
        // it off would put the site back on its first-run page.
        var hostile = stored
        hostile.setupComplete = false
        let afterHostile = try await client.updateSettings(hostile)
        #expect(afterHostile.setupComplete, "the setup flag was writable over the API")

        _ = try await client.updateSettings(before)

        let restored = try await client.settings()
        #expect(restored.title == before.title)
        #expect(restored.theme.accent == before.theme.accent)
    }

    /// Values out of range are clamped on the way to disk, and the response is
    /// the only account of what the site is actually using.
    @Test func clampsSettingsItWillNotAccept() async throws {
        let client = try #require(LiveServer.client)

        let before = try await client.settings()

        var absurd = before
        absurd.maxUploadMB = 999_999
        let stored = try await client.updateSettings(absurd)

        #expect(stored.maxUploadMB <= SiteSettings.Limits.uploadCeilingMB)
        #expect(stored.maxUploadMB != 999_999)

        _ = try await client.updateSettings(before)
    }

    /// A date format the server does not understand is ignored rather than
    /// stored, or every post on the site loses its date.
    @Test func refusesAnInvalidDateFormat() async throws {
        let client = try #require(LiveServer.client)

        let before = try await client.settings()

        var bad = before
        bad.dateFormat = "totally not a format <>{}"
        let stored = try await client.updateSettings(bad)

        #expect(stored.dateFormat == before.dateFormat)
    }

    /// A wrong token has to come back as something the person can act on rather
    /// than as a generic failure.
    @Test func rejectsABadToken() async throws {
        let real = try #require(LiveServer.client)

        let wrong = BroadsideClient(baseURL: real.baseURL, token: "not-a-real-token")

        await #expect(throws: APIError.unauthorized) {
            _ = try await wrong.posts(limit: 1)
        }
    }

    /// The smallest valid PNG: one opaque pixel.
    static let onePixelPNG = """
    iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==
    """
}

private extension String {
    /// The body without the newline the server puts on the end of every file.
    ///
    /// `content.Marshal` on the Go side appends one if the body does not
    /// already have it, because a file that does not end in a newline shows up
    /// as a spurious change in git and irritates every diff tool there is. That
    /// newline therefore belongs to the server, and neither this editor nor the
    /// web one writes it, so comparing against a body that has just come back
    /// from the server has to allow for it.
    ///
    /// This is not papering over a mismatch: both editors send exactly the same
    /// bytes, and the file on disk is identical whichever one saved it.
    var withoutTrailingNewline: String {
        hasSuffix("\n") ? String(dropLast()) : self
    }
}
