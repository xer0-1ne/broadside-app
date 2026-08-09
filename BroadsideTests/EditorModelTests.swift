import Testing
import Foundation
@testable import Broadside

@MainActor
struct EditorModelTests {

    /// A post opened and not touched has no changes.
    ///
    /// This looks too obvious to test, and it was wrong. Bodies come back from
    /// the server with a trailing newline that `content.Marshal` adds to every
    /// file, and the editor does not write one, so comparing the two directly
    /// reported every untouched post as modified. The visible result was a
    /// "discard your changes?" prompt in front of somebody who had made none,
    /// on every post on the site, and swipe to dismiss disabled along with it.
    @Test func anUntouchedPostHasNoChanges() {
        let post = Post(
            slug: "eagle-nebula",
            title: "Eagle Nebula Stack",
            body: "![Eagle Nebula](/uploads/01.jpg)\n\nTen hours of exposure.\n",
            path: "2026/08/08/01-eagle.md"
        )

        let model = EditorModel(post: post)
        #expect(!model.hasChanges)
    }

    /// The same, for the shapes most likely to have their own whitespace
    /// quirks on the way back from the server.
    @Test(arguments: [
        "A plain paragraph.\n",
        "## A heading\n",
        ":::gallery{caption=\"Two\"}\n![One](/uploads/01.png)\n![Two](/uploads/02.png)\n:::\n",
        "| a | b |\n|---|---|\n| 1 | 2 |\n",
        "- One\n- Two\n",
    ])
    func noSpuriousChangesFor(_ body: String) {
        let model = EditorModel(post: Post(title: "T", body: body, path: "a/b.md"))
        #expect(!model.hasChanges, "an untouched post reported changes for:\n\(body)")
    }

    /// And an actual edit still registers, or the guard above would be a way of
    /// silently throwing work away.
    @Test func anEditIsNoticed() {
        let model = EditorModel(post: Post(title: "T", body: "One.\n", path: "a/b.md"))
        #expect(!model.hasChanges)

        model.blocks.append(Block(kind: .paragraph(text: "Two.")))
        #expect(model.hasChanges)
    }

    @Test func aTitleChangeIsNoticed() {
        let model = EditorModel(post: Post(title: "T", body: "One.\n", path: "a/b.md"))
        model.title = "Something else"
        #expect(model.hasChanges)
    }

    /// Converting between types carries the words across where both sides have
    /// somewhere to put them.
    @Test func conversionCarriesTextAcross() {
        let model = EditorModel(post: Post(title: "T", body: "A sentence.\n", path: "a/b.md"))
        let id = model.blocks[0].id

        model.convert(blockID: id, to: .quote(text: ""))
        guard case let .quote(text) = model.blocks[0].kind else {
            Issue.record("expected a quote, got \(model.blocks[0].kind)")
            return
        }
        #expect(text == "A sentence.")

        // And into a list, which splits on lines rather than keeping one string.
        model.convert(blockID: id, to: .bulleted(items: []))
        guard case let .bulleted(items) = model.blocks[0].kind else {
            Issue.record("expected a list, got \(model.blocks[0].kind)")
            return
        }
        #expect(items == ["A sentence."])
    }

    /// Deleting the last block leaves something to type into rather than an
    /// empty screen with no way back.
    @Test func alwaysLeavesABlock() {
        let model = EditorModel(post: Post(title: "T", body: "One.\n", path: "a/b.md"))
        model.remove(at: IndexSet(integer: 0))
        #expect(model.blocks.count == 1)
    }

    /// A post with no title cannot be saved, since the server rejects it and
    /// the failure would arrive as an alert after the fact.
    @Test func requiresATitle() {
        let model = EditorModel(post: Post(title: "", body: "", path: ""))
        #expect(!model.canSave)

        model.title = "  "
        #expect(!model.canSave, "whitespace is not a title")

        model.title = "Real"
        #expect(model.canSave)
    }
}
