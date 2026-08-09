import Testing
@testable import Broadside

/// These pin the one thing in the app that can corrupt somebody's files.
///
/// The app and the web editor both parse a post into blocks and write it back
/// out. If they disagree by so much as a space, an author who edits on a phone
/// and then on a desktop gets a rewritten file every time they switch, and the
/// diff noise buries whatever they actually changed. So the assertions below
/// are mostly "in equals out", over the constructs most likely to drift.
struct BlockDocumentTests {

    /// The important one. Anything that survives parsing has to come back
    /// unchanged, because the alternative is silent damage rather than an
    /// error somebody would notice.
    @Test(arguments: [
        "A plain paragraph.",

        "A paragraph that runs\nacross two source lines.",

        "## A heading",

        "### A deeper heading",

        "> A quote.\n> Over two lines.",

        "- One\n- Two\n- Three",

        "1. One\n2. Two\n3. Three",

        "```swift\nlet x = 1\n```",

        "```\nno language\n```",

        "---",

        "![Alt text](/uploads/2026/08/08/01-plate.png)",

        "![Alt text](/uploads/2026/08/08/01-plate.png \"A caption\")",

        ":::gallery{caption=\"Five plates\"}\n"
            + "![One](/uploads/01.png \"First\")\n"
            + "![Two](/uploads/02.png)\n"
            + "![Three](/uploads/03.png \"Third\")\n"
            + ":::",

        ":::gallery{}\n![One](/uploads/01.png)\n![Two](/uploads/02.png)\n:::",

        ":::video{src=\"/uploads/clip.mp4\"}\n:::",

        ":::video{src=\"/uploads/clip.mp4\" poster=\"/uploads/poster.png\" caption=\"A clip\"}\n:::",

        ":::file{src=\"/uploads/spec.pdf\" name=\"spec.pdf\"}\n:::",

        ":::embed{url=\"https://example.com\" title=\"Example\"}\n:::",

        "| a | b |\n|---|---|\n| 1 | 2 |",
    ])
    func roundTripsUnchanged(_ source: String) {
        let result = BlockDocument.serialize(BlockDocument.parse(source))
        #expect(result == source)
    }

    /// A whole post rather than one construct, since the failures that matter
    /// tend to be about how blocks abut one another.
    @Test func roundTripsAWholePost() {
        let source = """
        The stack below is five separate plates from the same session.

        :::gallery{caption="Five plates, north up"}
        ![First plate](/uploads/2026/08/08/01-plate.png "The opening frame")
        ![Second plate](/uploads/2026/08/08/02-plate.png)
        :::

        ## What the equipment was

        - SV503 80ED
        - An unreasonable number of darks

        > Seeing was better than forecast.

        | Frame | Minutes |
        |---|---|
        | Light | 240 |

        ---

        ![A lone plate](/uploads/2026/08/08/01-plate.png "On its own")

        That is the end of the post.
        """

        #expect(BlockDocument.serialize(BlockDocument.parse(source)) == source)
    }

    /// A table has no block type of its own, so it has to come back through the
    /// passthrough case. Losing this is how editing a hand-written post on a
    /// phone silently deletes the table in it.
    @Test func keepsMarkdownItCannotModel() {
        let source = "| a | b |\n|---|---|\n| 1 | 2 |"
        let blocks = BlockDocument.parse(source)

        #expect(blocks.count == 1)
        guard case let .raw(text) = blocks[0].kind else {
            Issue.record("a table should parse as a passthrough block, got \(blocks[0].kind)")
            return
        }
        #expect(text == source)
    }

    /// Adding a second picture is what turns an image into a gallery. Nothing
    /// else in the app decides this, so it is worth asserting in both
    /// directions.
    @Test func aSecondPictureMakesAGallery() {
        let one = Block(kind: .image(
            pictures: [.init(src: "/uploads/01.png", alt: "One")],
            caption: "Just the one"
        ))
        #expect(BlockDocument.markdown(for: one) == "![One](/uploads/01.png \"Just the one\")")

        let two = Block(kind: .image(
            pictures: [
                .init(src: "/uploads/01.png", alt: "One"),
                .init(src: "/uploads/02.png", alt: "Two"),
            ],
            caption: "Both of them"
        ))
        #expect(BlockDocument.markdown(for: two) == """
        :::gallery{caption="Both of them"}
        ![One](/uploads/01.png)
        ![Two](/uploads/02.png)
        :::
        """)
    }

    /// A row the author opened and never filled in is not a picture, and
    /// writing it out would put an empty image in the file.
    @Test func dropsPicturesWithNoSource() {
        let block = Block(kind: .image(
            pictures: [
                .init(src: "/uploads/01.png", alt: "One"),
                .init(src: "", alt: ""),
                .init(src: "/uploads/03.png", alt: "Three"),
            ],
            caption: ""
        ))

        let markdown = BlockDocument.markdown(for: block)
        #expect(!markdown.contains("]()"))
        #expect(markdown.components(separatedBy: "![").count - 1 == 2)
    }

    /// The web editor clamps headings to the range the site styles, so this one
    /// deliberately does not round trip. Asserting the rewrite is the point:
    /// both editors have to do it, or one will keep undoing the other.
    @Test func clampsHeadingsToTheStyledRange() {
        #expect(BlockDocument.serialize(BlockDocument.parse("# Top")) == "## Top")
        #expect(BlockDocument.serialize(BlockDocument.parse("##### Deep")) == "#### Deep")
    }

    /// A quote in the middle of a line is not a quote, and an image in the
    /// middle of a sentence is not a figure. Both stay inside the paragraph.
    @Test func leavesInlineConstructsAlone() {
        let source = "Text with ![an image](/uploads/01.png) inside it."
        let blocks = BlockDocument.parse(source)

        #expect(blocks.count == 1)
        guard case let .paragraph(text) = blocks[0].kind else {
            Issue.record("expected a paragraph, got \(blocks[0].kind)")
            return
        }
        #expect(text == source)
    }

    /// An empty body still has to produce something to type into.
    @Test func alwaysYieldsAtLeastOneBlock() {
        #expect(BlockDocument.parse("").count == 1)
        #expect(BlockDocument.parse("\n\n\n").count == 1)
    }

    /// An unterminated fence used to be able to spin the parser, since neither
    /// the fence branch nor the paragraph branch consumed the line.
    @Test func terminatesOnMalformedInput() {
        #expect(!BlockDocument.parse("```swift\nlet x = 1").isEmpty)
        #expect(!BlockDocument.parse(":::gallery{").isEmpty)
        #expect(!BlockDocument.parse(":::").isEmpty)
        #expect(!BlockDocument.parse("```js extra").isEmpty)
    }
}
