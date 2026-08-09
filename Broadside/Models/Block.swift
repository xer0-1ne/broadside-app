import Foundation

/// A block of a post.
///
/// This is a Swift port of the block model in
/// `internal/server/static/js/editor.js`, and the two have to agree. A post
/// opened in the web editor, saved, opened here and saved again must come back
/// byte for byte, or an author who works on a phone and a desktop will find one
/// of them quietly rewriting their files.
///
/// `BlockDocumentTests` pins that with round trips over the same fixtures the
/// web editor is exercised against. When adding a block type, add it in both
/// places and in `render` on the Go side, or it will parse in one and vanish in
/// the other.
struct Block: Identifiable, Hashable, Sendable {
    let id: UUID
    var kind: Kind

    init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }

    /// The closed set of block types. Closed on purpose: every one of these has
    /// to survive a round trip through markdown, so a type is only added once
    /// its markdown form exists.
    enum Kind: Hashable, Sendable {
        case paragraph(text: String)
        case heading(level: Int, text: String)
        case quote(text: String)
        case code(language: String, text: String)
        case bulleted(items: [String])
        case numbered(items: [String])

        /// One picture or many. More than one serializes as a gallery, which is
        /// the same rule the web editor follows: adding a second image is what
        /// makes it a gallery, rather than choosing a different block up front.
        case image(pictures: [Picture], caption: String)

        case video(src: String, poster: String, caption: String)
        case file(src: String, name: String)
        case embed(url: String, title: String)
        case divider

        /// Markdown this editor does not model, kept exactly as written.
        ///
        /// Without this, opening a post containing a table and saving it would
        /// silently delete the table. That is the worst failure available to a
        /// tool whose promise is that the files stay yours.
        case raw(text: String)
    }

    /// One image inside a picture block.
    struct Picture: Identifiable, Hashable, Sendable {
        let id: UUID
        var src: String
        var alt: String

        /// Shown in the lightbox when this specific picture is on screen, as
        /// distinct from the caption under the gallery as a whole.
        var caption: String

        init(id: UUID = UUID(), src: String = "", alt: String = "", caption: String = "") {
            self.id = id
            self.src = src
            self.alt = alt
            self.caption = caption
        }
    }
}

extension Block.Kind {
    /// The name shown in the type picker.
    var label: String {
        switch self {
        case .paragraph: "Text"
        case .heading: "Heading"
        case .quote: "Quote"
        case .code: "Code"
        case .bulleted: "Bulleted list"
        case .numbered: "Numbered list"
        case .image: "Picture"
        case .video: "Video"
        case .file: "File"
        case .embed: "Embed"
        case .divider: "Divider"
        case .raw: "Markdown"
        }
    }

    var symbolName: String {
        switch self {
        case .paragraph: "text.alignleft"
        case .heading: "textformat.size"
        case .quote: "quote.opening"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .bulleted: "list.bullet"
        case .numbered: "list.number"
        case .image: "photo"
        case .video: "video"
        case .file: "paperclip"
        case .embed: "link"
        case .divider: "minus"
        case .raw: "curlybraces"
        }
    }

    /// The types offered when inserting a block. `raw` is missing on purpose:
    /// it is what unrecognised markdown becomes, not something to choose.
    static let insertable: [Block.Kind] = [
        .paragraph(text: ""),
        .heading(level: 2, text: ""),
        .image(pictures: [Block.Picture()], caption: ""),
        .bulleted(items: [""]),
        .numbered(items: [""]),
        .quote(text: ""),
        .code(language: "", text: ""),
        .video(src: "", poster: "", caption: ""),
        .file(src: "", name: ""),
        .embed(url: "", title: ""),
        .divider,
    ]

    /// Whether two kinds are the same case, ignoring their contents. Used by
    /// the type picker to mark the current one.
    func isSameCase(as other: Block.Kind) -> Bool {
        label == other.label
    }
}
