import Foundation

/// A post as the server sends it.
///
/// The field names and optionality here mirror `apiPost` in
/// `internal/server/posts.go` exactly, including which keys carry `omitempty`.
/// That correspondence is the contract between the two halves of the project,
/// and it is worth checking against the Go struct rather than against a sample
/// response, because a field that is merely absent from one post looks
/// identical to a field that does not exist.
struct Post: Codable, Identifiable, Hashable, Sendable {
    var slug: String
    var title: String
    var published: Date
    var updated: Date?
    var draft: Bool
    var tags: [String]
    var summary: String
    var cover: String
    var body: String

    /// The public address of the post, and its path on disk. Both are assigned
    /// by the server; sending either back has no effect.
    var url: String
    var path: String

    /// The slug identifies a post everywhere in the API, so it is the identity
    /// here too rather than a client-side UUID that would not survive a reload.
    var id: String { slug }

    enum CodingKeys: String, CodingKey {
        case slug, title, published, updated, draft, tags, summary, cover, body, url, path
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        slug = try container.decodeIfPresent(String.self, forKey: .slug) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        published = try container.decodeIfPresent(Date.self, forKey: .published) ?? Date()
        updated = try container.decodeIfPresent(Date.self, forKey: .updated)
        draft = try container.decodeIfPresent(Bool.self, forKey: .draft) ?? false

        // These four are omitempty on the wire, so their absence is ordinary
        // and means empty rather than malformed.
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        cover = try container.decodeIfPresent(String.self, forKey: .cover) ?? ""
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""

        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
    }

    init(
        slug: String = "",
        title: String = "",
        published: Date = Date(),
        updated: Date? = nil,
        draft: Bool = false,
        tags: [String] = [],
        summary: String = "",
        cover: String = "",
        body: String = "",
        url: String = "",
        path: String = ""
    ) {
        self.slug = slug
        self.title = title
        self.published = published
        self.updated = updated
        self.draft = draft
        self.tags = tags
        self.summary = summary
        self.cover = cover
        self.body = body
        self.url = url
        self.path = path
    }
}

extension Post {
    /// What the post is doing right now, which is not a field on the wire: it
    /// is the draft flag and the publication date read together.
    enum State: Hashable, Sendable {
        case draft
        case scheduled
        case published
    }

    func state(now: Date = Date()) -> State {
        if draft { return .draft }
        if published > now { return .scheduled }
        return .published
    }

    /// The body the editor works on, rebuilt from blocks on save.
    var blocks: [Block] {
        get { BlockDocument.parse(body) }
        set { body = BlockDocument.serialize(newValue) }
    }
}

extension Post.State {
    var label: String {
        switch self {
        case .draft: "Draft"
        case .scheduled: "Scheduled"
        case .published: "Published"
        }
    }
}

/// The body a create or update request sends.
///
/// This is deliberately not `Post`. An update is decoded onto the post the
/// server already has, so anything sent overwrites and anything omitted is
/// kept. Sending the whole of `Post` back would include `url` and `path`, which
/// the server assigns and would then have to ignore, and sending a `published`
/// the client never meant to change is how a scheduled post accidentally goes
/// out early.
struct PostSubmission: Encodable, Sendable {
    var slug: String
    var title: String
    var body: String
    var draft: Bool
    var tags: [String]
    var summary: String
    var cover: String

    /// Omitted entirely when nil. The server treats a zero time as "leave the
    /// publication date alone", and a nil here is what produces that.
    var published: Date?

    init(from post: Post, includePublished: Bool = true) {
        slug = post.slug
        title = post.title
        body = post.body
        draft = post.draft
        tags = post.tags
        summary = post.summary
        cover = post.cover
        published = includePublished ? post.published : nil
    }
}

/// One uploaded file, as `/api/media` lists them.
struct MediaItem: Codable, Identifiable, Hashable, Sendable {
    var url: String
    var name: String
    var size: Int64
    var modified: Date

    var id: String { url }

    /// Whether this is something the app can show inline. The server stores the
    /// extension it assigned after sniffing the bytes, so this is reading a
    /// value Broadside chose rather than one a client claimed.
    var isImage: Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "gif", "webp", "avif", "heic"].contains(ext)
    }
}
