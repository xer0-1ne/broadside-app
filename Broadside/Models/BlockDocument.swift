import Foundation

/// Turns a post body into blocks and back.
///
/// This is the Swift half of a pair. The other half is `parse()` and
/// `serialize()` in `internal/server/static/js/editor.js`, and the two are
/// written to produce identical output from identical input. Where the logic
/// below looks arbitrary — the heading clamp, the ordering of the checks, the
/// rule about when a picture block becomes a gallery — it is matching that file
/// deliberately, and changing it here alone is how the phone and the browser
/// start disagreeing about what a post says.
enum BlockDocument {

    // MARK: - Parsing

    static func parse(_ markdown: String) -> [Block] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")

        let patterns = Patterns()
        var blocks: [Block] = []
        var i = 0

        while i < lines.count {
            let line = lines[i]

            if line.trimmed.isEmpty {
                i += 1
                continue
            }

            // Fenced code first, because its contents can look like any other
            // construct and anything else matching inside it would be wrong.
            if let fence = line.wholeMatch(of: patterns.fenceOpen) {
                let language = String(fence.1)
                var body: [String] = []
                i += 1
                while i < lines.count, lines[i].wholeMatch(of: patterns.fenceClose) == nil {
                    body.append(lines[i])
                    i += 1
                }
                i += 1 // the closing fence
                blocks.append(Block(kind: .code(language: language, text: body.joined(separator: "\n"))))
                continue
            }

            // Container directives.
            if let directive = line.wholeMatch(of: patterns.directive),
               let kind = DirectiveName(rawValue: String(directive.1)) {
                let attributes = parseAttributes(String(directive.2), patterns: patterns)
                var inner: [String] = []
                i += 1
                while i < lines.count, lines[i].trimmed != ":::" {
                    inner.append(lines[i])
                    i += 1
                }
                i += 1 // the closing marker

                blocks.append(Block(kind: kind.block(attributes: attributes, body: inner, patterns: patterns)))
                continue
            }

            // Before the bulleted list, or "---" would be read as a list of
            // nothing. The list check below requires whitespace after the
            // marker, so the two cannot collide, but the order still matters
            // for anyone reading this later.
            if line.wholeMatch(of: patterns.divider) != nil {
                blocks.append(Block(kind: .divider))
                i += 1
                continue
            }

            if let heading = line.wholeMatch(of: patterns.heading) {
                // Clamped to the range the site styles. The post title is the
                // page's only h1, and a second one breaks the document outline
                // that screen readers and search engines depend on.
                let level = min(max(heading.1.count, 2), 4)
                blocks.append(Block(kind: .heading(level: level, text: String(heading.2))))
                i += 1
                continue
            }

            // An image alone on its line is a block. One inside a sentence is
            // not, and stays part of the paragraph.
            if let image = line.wholeMatch(of: patterns.image) {
                let picture = Block.Picture(src: String(image.2), alt: String(image.1))
                let caption = image.3.map(String.init) ?? ""
                blocks.append(Block(kind: .image(pictures: [picture], caption: caption)))
                i += 1
                continue
            }

            if line.hasPrefix(">") {
                var body: [String] = []
                while i < lines.count, lines[i].hasPrefix(">") {
                    body.append(lines[i].strippingQuoteMarker)
                    i += 1
                }
                blocks.append(Block(kind: .quote(text: body.joined(separator: "\n"))))
                continue
            }

            if line.isBulletedItem {
                var items: [String] = []
                while i < lines.count, lines[i].isBulletedItem {
                    items.append(lines[i].strippingBullet)
                    i += 1
                }
                blocks.append(Block(kind: .bulleted(items: items)))
                continue
            }

            if line.isNumberedItem {
                var items: [String] = []
                while i < lines.count, lines[i].isNumberedItem {
                    items.append(lines[i].strippingNumber)
                    i += 1
                }
                blocks.append(Block(kind: .numbered(items: items)))
                continue
            }

            // A table, or anything else with structure this editor cannot
            // model, is kept whole rather than flattened into paragraphs.
            if line.hasPrefix("|") {
                var body: [String] = []
                while i < lines.count, !lines[i].trimmed.isEmpty {
                    body.append(lines[i])
                    i += 1
                }
                blocks.append(Block(kind: .raw(text: body.joined(separator: "\n"))))
                continue
            }

            // Everything else is a paragraph, running to the next blank line or
            // to the first line that starts a block of its own.
            var paragraph: [String] = []
            while i < lines.count, !lines[i].trimmed.isEmpty, !lines[i].startsSomeOtherBlock {
                paragraph.append(lines[i])
                i += 1
            }

            if paragraph.isEmpty {
                // A line that matched none of the branches above and also
                // failed the paragraph test. Without this the loop would never
                // advance past it.
                blocks.append(Block(kind: .raw(text: line)))
                i += 1
            } else {
                blocks.append(Block(kind: .paragraph(text: paragraph.joined(separator: "\n"))))
            }
        }

        return blocks.isEmpty ? [Block(kind: .paragraph(text: ""))] : blocks
    }

    // MARK: - Serializing

    static func serialize(_ blocks: [Block]) -> String {
        blocks
            .map(markdown(for:))
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    static func markdown(for block: Block) -> String {
        switch block.kind {
        case let .paragraph(text):
            return text

        case let .heading(level, text):
            return String(repeating: "#", count: level) + " " + text

        case let .quote(text):
            return text.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")

        case let .code(language, text):
            return "```" + language + "\n" + text + "\n```"

        case let .bulleted(items):
            return items.map { "- " + $0 }.joined(separator: "\n")

        case let .numbered(items):
            return items.enumerated().map { "\($0.offset + 1). " + $0.element }.joined(separator: "\n")

        case let .image(pictures, caption):
            return galleryMarkdown(pictures: pictures, caption: caption)

        case let .video(src, poster, caption):
            guard !src.isEmpty else { return "" }
            var out = #":::video{src=""# + src + "\""
            if !poster.isEmpty { out += #" poster=""# + poster + "\"" }
            if !caption.isEmpty { out += #" caption=""# + quoteSafe(caption) + "\"" }
            return out + "}\n:::"

        case let .file(src, name):
            guard !src.isEmpty else { return "" }
            var out = #":::file{src=""# + src + "\""
            if !name.isEmpty { out += #" name=""# + quoteSafe(name) + "\"" }
            return out + "}\n:::"

        case let .embed(url, title):
            guard !url.isEmpty else { return "" }
            var out = #":::embed{url=""# + url + "\""
            if !title.isEmpty { out += #" title=""# + quoteSafe(title) + "\"" }
            return out + "}\n:::"

        case .divider:
            return "---"

        case let .raw(text):
            return text
        }
    }

    /// One picture is written as ordinary markdown and only two or more become
    /// a gallery, so a post with a single photograph stays a post with a plain
    /// image in it, readable by anything that reads markdown.
    private static func galleryMarkdown(pictures: [Block.Picture], caption: String) -> String {
        let usable = pictures.filter { !$0.src.isEmpty }
        guard !usable.isEmpty else { return "" }

        if usable.count == 1 {
            // With one picture there is no gallery to caption, so the block's
            // caption and the picture's own are the same thing and only one of
            // them is holding text.
            let only = usable[0]
            let text = only.caption.isEmpty ? caption : only.caption
            return "![\(only.alt)](\(only.src)\(titleSuffix(text)))"
        }

        var out = ":::gallery{"
        if !caption.isEmpty { out += #"caption=""# + quoteSafe(caption) + "\"" }
        out += "}\n"
        out += usable
            .map { "![\($0.alt)](\($0.src)\(titleSuffix($0.caption)))" }
            .joined(separator: "\n")
        return out + "\n:::"
    }

    private static func titleSuffix(_ text: String) -> String {
        text.isEmpty ? "" : " \"" + quoteSafe(text) + "\""
    }

    /// Attribute values sit between double quotes, so one inside would end the
    /// value early and the rest would be read as further attributes. Dropping
    /// the character is blunt, and it is what the web editor does; the
    /// alternative is an escaping rule the hand-editable file format would then
    /// have to explain.
    private static func quoteSafe(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: "")
    }

    // MARK: - Directives

    private enum DirectiveName: String {
        case video, file, embed, gallery

        func block(attributes: [String: String], body: [String], patterns: Patterns) -> Block.Kind {
            switch self {
            case .video:
                return .video(
                    src: attributes["src"] ?? "",
                    poster: attributes["poster"] ?? "",
                    caption: attributes["caption"] ?? ""
                )

            case .file:
                return .file(src: attributes["src"] ?? "", name: attributes["name"] ?? "")

            case .embed:
                return .embed(url: attributes["url"] ?? "", title: attributes["title"] ?? "")

            case .gallery:
                let pictures: [Block.Picture] = body.compactMap { line in
                    guard let match = line.wholeMatch(of: patterns.image) else { return nil }
                    return Block.Picture(
                        src: String(match.2),
                        alt: String(match.1),
                        caption: match.3.map(String.init) ?? ""
                    )
                }
                return .image(
                    pictures: pictures.isEmpty ? [Block.Picture()] : pictures,
                    caption: attributes["caption"] ?? ""
                )
            }
        }
    }

    private static func parseAttributes(_ text: String, patterns: Patterns) -> [String: String] {
        var attributes: [String: String] = [:]
        for match in text.matches(of: patterns.attribute) {
            attributes[String(match.1)] = String(match.2)
        }
        return attributes
    }

    // MARK: - Patterns

    /// The patterns, built once per parse and passed down.
    ///
    /// They are instance properties rather than statics because `Regex`
    /// compiles itself lazily on first use, which is shared mutable state and
    /// is why the type is not `Sendable`. One set per call to `parse` is a
    /// handful of constructions for a whole post, against a correctness
    /// problem that would only ever show up under concurrency and would be
    /// miserable to reproduce.
    private struct Patterns {
        let fenceOpen = /```(\w*)\s*/
        let fenceClose = /```\s*/
        let directive = /:::(\w+)\{(.*)\}\s*/
        let divider = /-{3,}\s*/
        let heading = /(#{1,6})\s+(.*)/
        let attribute = /(\w+)="([^"]*)"/

        /// One markdown image occupying a whole line, used both for a
        /// standalone picture and for each line inside a gallery. This mirrors
        /// `IMAGE_LINE` in editor.js and `galleryImagePattern` in
        /// `internal/render/gallery.go`; all three have to agree on what counts
        /// as an image or a gallery saved in one place comes back short in
        /// another.
        let image = /\s*!\[([^\]]*)\]\(\s*(\S+?)(?:\s+"([^"]*)")?\s*\)\s*/
    }
}

// MARK: - Line classification

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespaces)
    }

    var strippingQuoteMarker: String {
        var rest = dropFirst()          // the ">"
        if rest.first == " " { rest = rest.dropFirst() }
        return String(rest)
    }

    var isBulletedItem: Bool {
        guard let first, "-*+".contains(first) else { return false }
        guard let second = dropFirst().first else { return false }
        return second.isWhitespace
    }

    var strippingBullet: String {
        String(dropFirst().drop(while: \.isWhitespace))
    }

    var isNumberedItem: Bool {
        let digits = prefix(while: \.isNumber)
        guard !digits.isEmpty else { return false }
        let rest = dropFirst(digits.count)
        guard let marker = rest.first, marker == "." || marker == ")" else { return false }
        guard let after = rest.dropFirst().first else { return false }
        return after.isWhitespace
    }

    var strippingNumber: String {
        let digits = prefix(while: \.isNumber)
        return String(dropFirst(digits.count + 1).drop(while: \.isWhitespace))
    }

    /// Whether this line begins a block of its own, and therefore ends the
    /// paragraph being collected. The set matches the guard in editor.js.
    var startsSomeOtherBlock: Bool {
        if hasPrefix(">") || hasPrefix("```") || hasPrefix(":::") || hasPrefix("|") { return true }
        if isBulletedItem || isNumberedItem { return true }

        let hashes = prefix(while: { $0 == "#" })
        if !hashes.isEmpty, hashes.count <= 6,
           let after = dropFirst(hashes.count).first, after.isWhitespace {
            return true
        }

        let dashes = prefix(while: { $0 == "-" })
        if dashes.count >= 3, dropFirst(dashes.count).allSatisfy(\.isWhitespace) { return true }

        return false
    }
}
