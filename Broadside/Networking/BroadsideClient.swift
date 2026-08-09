import Foundation

/// The HTTP client for one Broadside server.
///
/// A value type holding an address and a token, with no state of its own, so it
/// is cheap to make and safe to hand across actors. Everything it does maps
/// onto a route in `internal/server/server.go`; there is no cleverness here and
/// no client-side cache, because the server is one process on somebody's own
/// hardware and a request to it is not expensive.
struct BroadsideClient: Sendable {
    let baseURL: URL
    private let token: String

    private let session: URLSession

    init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    // MARK: - Posts

    /// One page of posts, newest first, with the cursor for the page after it.
    ///
    /// The server paginates by cursor rather than page number so that a post
    /// published while somebody is scrolling cannot make them skip or repeat
    /// one, and that property only holds if the cursor is passed back.
    func posts(after cursor: String? = nil, limit: Int = 20, includeDrafts: Bool = true) async throws -> PostPage {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        if !includeDrafts { query.append(URLQueryItem(name: "drafts", value: "false")) }

        let data = try await send(request(path: "/api/posts", query: query))
        return try decode(PostPage.self, from: data)
    }

    /// One post, body included. The list endpoint omits bodies, so this is the
    /// call the editor needs before it can open anything.
    func post(slug: String) async throws -> Post {
        let data = try await send(request(path: "/api/posts/\(slug.pathEscaped)"))
        return try decode(Post.self, from: data)
    }

    func create(_ submission: PostSubmission) async throws -> Post {
        var req = request(path: "/api/posts", method: "POST")
        req.httpBody = try encoder.encode(submission)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let data = try await send(req)
        return try decode(Post.self, from: data)
    }

    /// A partial update. The server decodes onto the post it already has, so
    /// anything omitted from the submission keeps the value it had.
    func update(slug: String, with submission: PostSubmission) async throws -> Post {
        var req = request(path: "/api/posts/\(slug.pathEscaped)", method: "PATCH")
        req.httpBody = try encoder.encode(submission)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let data = try await send(req)
        return try decode(Post.self, from: data)
    }

    func delete(slug: String) async throws {
        _ = try await send(request(path: "/api/posts/\(slug.pathEscaped)", method: "DELETE"))
    }

    // MARK: - Settings

    func settings() async throws -> SiteSettings {
        let data = try await sendToSettings(request(path: "/api/settings"))
        return try decode(SiteSettings.self, from: data)
    }

    /// Saves settings and returns what the server actually stored.
    ///
    /// The returned value matters and is not the same as what was sent. The
    /// upload limit and the password length are both clamped on the way to
    /// disk, so a client that keeps its own copy rather than adopting the
    /// response will show a number the site is not using.
    func updateSettings(_ settings: SiteSettings) async throws -> SiteSettings {
        var req = request(path: "/api/settings", method: "PATCH")
        req.httpBody = try encoder.encode(settings)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let data = try await sendToSettings(req)
        return try decode(SiteSettings.self, from: data)
    }

    /// The settings routes, with a 404 read as "this server predates them".
    ///
    /// There is no post to be missing on these two, so the only thing a 404 can
    /// mean is that the binary on the other end does not have the route. That
    /// is an ordinary situation for self-hosted software, where the app updates
    /// itself and the server updates when its owner gets round to it.
    private func sendToSettings(_ request: URLRequest) async throws -> Data {
        do {
            return try await send(request)
        } catch APIError.notFound {
            throw APIError.notSupported(feature: "the settings API")
        }
    }

    // MARK: - Media

    func media() async throws -> [MediaItem] {
        let data = try await send(request(path: "/api/media"))
        return try decode(MediaList.self, from: data).media
    }

    /// Uploads a file already on disk, in the foreground.
    ///
    /// This is for small things chosen and sent while somebody is watching.
    /// Photographs go through `MediaUploader` instead, which hands the transfer
    /// to the system so it survives the app being suspended; a 300MB frame sent
    /// through here dies the moment the person switches apps.
    func upload(fileURL: URL, filename: String, contentType: String) async throws -> String {
        let boundary = "broadside.\(UUID().uuidString)"
        var req = request(path: "/api/media", method: "POST")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let body = try MultipartBody.make(
            fileURL: fileURL,
            filename: filename,
            contentType: contentType,
            boundary: boundary
        )
        defer { try? FileManager.default.removeItem(at: body) }

        let data = try await send(req, uploading: body)
        return try decode(UploadResult.self, from: data).url
    }

    /// Everything the background uploader needs to build the same request
    /// without holding a client of its own.
    func uploadRequest(boundary: String) -> URLRequest {
        var req = request(path: "/api/media", method: "POST")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        return req
    }

    /// Resolves a path the server returned, such as "/uploads/2026/…", against
    /// the server's address so it can be loaded.
    func absoluteURL(for path: String) -> URL? {
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return URL(string: path)
        }
        return URL(string: path, relativeTo: baseURL)?.absoluteURL
    }

    // MARK: - Plumbing

    private func request(path: String, method: String = "GET", query: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(
            url: baseURL.appending(path: path),
            resolvingAgainstBaseURL: false
        )
        if !query.isEmpty { components?.queryItems = query }

        var req = URLRequest(url: components?.url ?? baseURL.appending(path: path))
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        // A self-hosted server can be a Raspberry Pi on a slow uplink, and the
        // default of 60 seconds is not generous enough for one waking up.
        req.timeoutInterval = 30
        return req
    }

    private func send(_ request: URLRequest, uploading file: URL? = nil) async throws -> Data {
        do {
            let (data, response): (Data, URLResponse)
            if let file {
                (data, response) = try await session.upload(for: request, fromFile: file)
            } else {
                (data, response) = try await session.data(for: request)
            }

            guard let http = response as? HTTPURLResponse else { throw APIError.malformedResponse }

            switch http.statusCode {
            case 200..<300:
                return data
            case 401, 403:
                throw APIError.unauthorized
            case 404:
                throw APIError.notFound
            case 413:
                throw APIError.tooLarge
            default:
                // The server puts a sentence in {"error": …} on every failure,
                // and it is almost always more useful than the status code.
                throw APIError.server(status: http.statusCode, message: Self.message(in: data))
            }
        } catch let error as APIError {
            throw error
        } catch let error as URLError {
            throw APIError.transport(Self.describe(error))
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw APIError.malformedResponse
        }
    }

    private static func message(in data: Data) -> String {
        struct Envelope: Decodable { let error: String? }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?.error ?? ""
    }

    /// URLError's own descriptions are written for apps talking to a service
    /// somebody else runs. Here the person reading this owns the server, so
    /// naming what is actually wrong points them at the right thing.
    private static func describe(_ error: URLError) -> String {
        switch error.code {
        case .cannotFindHost, .cannotConnectToHost:
            "Nothing answered at that address. Check the server is running and the port is right."
        case .notConnectedToInternet:
            "This device is offline."
        case .timedOut:
            "The server took too long to answer."
        case .appTransportSecurityRequiresSecureConnection, .secureConnectionFailed:
            "That address needs HTTPS. Plain HTTP is only allowed to servers on this network."
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot:
            "The server's certificate was not trusted by this device."
        default:
            error.localizedDescription
        }
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        // Go's encoding/json writes RFC 3339 with fractional seconds sometimes
        // and without them other times, depending on the clock the timestamp
        // came off. .iso8601 rejects the fractional form, which is a decode
        // failure on perfectly ordinary posts.
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = RFC3339.date(from: text) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "not an RFC 3339 timestamp: \(text)"
                )
            }
            return date
        }
        return decoder
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(RFC3339.string(from: date))
        }
        return encoder
    }
}

/// One page of posts.
struct PostPage: Decodable, Sendable {
    var posts: [Post]

    /// The cursor for the following page, absent on the last one. Its absence
    /// is what ends a paginated scroll.
    var next: String?
}

private struct MediaList: Decodable {
    let media: [MediaItem]
}

private struct UploadResult: Decodable {
    let url: String
}

/// Timestamps, in the one format the Go side reads and writes.
///
/// Both formatters are `nonisolated(unsafe)` rather than being rebuilt per
/// call. Foundation's date formatters are not marked `Sendable`, but Apple
/// documents them as safe to use concurrently once configured, and constructing
/// one is slow enough that doing it per timestamp would be felt on a page of
/// posts. Nothing below ever mutates them after this file has run, which is the
/// condition that makes the annotation true rather than merely convenient.
enum RFC3339 {
    nonisolated(unsafe) private static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func date(from text: String) -> Date? {
        withFraction.date(from: text) ?? plain.date(from: text)
    }

    /// Always written without fractional seconds. The server stores this
    /// verbatim in the frontmatter, and a timestamp a person might later edit
    /// by hand should not carry six decimal places for no reason.
    static func string(from date: Date) -> String {
        plain.string(from: date)
    }
}

private extension String {
    /// Escapes a slug for use as a path component. Slugs are already restricted
    /// to a safe alphabet by the server, so this is belt and braces rather than
    /// the only thing standing between a title and a malformed URL.
    var pathEscaped: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self
    }
}
