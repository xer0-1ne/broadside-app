import Foundation
import Observation

/// The post being edited, and everything that can happen to it.
@MainActor
@Observable
final class EditorModel {
    var title: String
    var blocks: [Block]
    var slug: String
    var tags: String
    var summary: String
    var isDraft: Bool
    var published: Date

    /// Where this came from. A post with no path on disk has never been saved,
    /// which decides whether saving creates or updates.
    private let original: Post
    private var isNew: Bool { original.path.isEmpty }

    /// The body as it would be written if nothing were touched.
    ///
    /// Comparing against `original.body` directly does not work, and the way it
    /// fails is quiet: the server appends a trailing newline to every file it
    /// writes, and this editor does not emit one, so a post opened and
    /// immediately closed looked modified. That put a "discard your changes?"
    /// prompt in front of somebody who had made none, and blocked swipe to
    /// dismiss on every post on the site.
    ///
    /// Running the original through the same parse and serialize the edited
    /// copy goes through makes the comparison about the blocks rather than
    /// about whitespace, which is the question actually being asked.
    private let baselineBody: String

    var isSaving = false
    var failure: String?

    /// Which picture each in-flight upload is filling in. Kept here rather than
    /// on the uploader because the uploader is process-wide and outlives any
    /// one editor.
    private var uploadTargets: [UUID: Target] = [:]

    private enum Target {
        case picture(block: UUID, picture: UUID)
        case videoSource(block: UUID)
        case videoPoster(block: UUID)
        case file(block: UUID)
    }

    init(post: Post) {
        original = post
        title = post.title
        blocks = BlockDocument.parse(post.body)
        baselineBody = BlockDocument.serialize(BlockDocument.parse(post.body))
        slug = post.slug
        tags = post.tags.joined(separator: ", ")
        summary = post.summary
        isDraft = post.draft
        published = post.published
    }

    var hasChanges: Bool {
        title != original.title
            || BlockDocument.serialize(blocks) != baselineBody
            || slug != original.slug
            || tags != original.tags.joined(separator: ", ")
            || summary != original.summary
            || isDraft != original.draft
            || published != original.published
    }

    var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSaving
    }

    // MARK: - Editing the stack

    func insert(_ kind: Block.Kind, after index: Int?) {
        let block = Block(kind: kind)
        if let index, index < blocks.count {
            blocks.insert(block, at: index + 1)
        } else {
            blocks.append(block)
        }
    }

    func remove(at offsets: IndexSet) {
        blocks.remove(atOffsets: offsets)
        if blocks.isEmpty { blocks = [Block(kind: .paragraph(text: ""))] }
    }

    func move(from source: IndexSet, to destination: Int) {
        blocks.move(fromOffsets: source, toOffset: destination)
    }

    /// Changes a block's type, carrying its words across where both sides have
    /// somewhere to put them.
    ///
    /// A paragraph becoming a quote keeps what was written. A paragraph
    /// becoming a picture cannot, and starts empty, which is honest: there is
    /// nowhere in a picture block for a sentence to go.
    func convert(blockID: UUID, to kind: Block.Kind) {
        guard let index = blocks.firstIndex(where: { $0.id == blockID }) else { return }

        let carried = text(of: blocks[index].kind)
        var replacement = kind

        switch replacement {
        case .paragraph: replacement = .paragraph(text: carried)
        case .quote: replacement = .quote(text: carried)
        case .raw: replacement = .raw(text: carried)
        case let .heading(level, _): replacement = .heading(level: level, text: carried)
        case let .code(language, _): replacement = .code(language: language, text: carried)
        case .bulleted:
            replacement = .bulleted(items: carried.isEmpty ? [""] : carried.components(separatedBy: "\n"))
        case .numbered:
            replacement = .numbered(items: carried.isEmpty ? [""] : carried.components(separatedBy: "\n"))
        default:
            break
        }

        blocks[index] = Block(id: blockID, kind: replacement)
    }

    private func text(of kind: Block.Kind) -> String {
        switch kind {
        case let .paragraph(text), let .quote(text), let .raw(text): text
        case let .heading(_, text): text
        case let .code(_, text): text
        case let .bulleted(items), let .numbered(items): items.joined(separator: "\n")
        default: ""
        }
    }

    // MARK: - Uploads

    func startPictureUpload(
        file: URL,
        filename: String,
        contentType: String,
        into blockID: UUID,
        picture pictureID: UUID,
        using client: BroadsideClient
    ) {
        let job = MediaUploader.shared.upload(
            fileURL: file,
            filename: filename,
            contentType: contentType,
            using: client
        )
        uploadTargets[job] = .picture(block: blockID, picture: pictureID)
    }

    /// Adds a picture row and starts filling it, so the slide appears in place
    /// immediately with a progress bar rather than arriving out of order once
    /// the transfer lands.
    @discardableResult
    func appendPicture(to blockID: UUID) -> UUID? {
        guard let index = blocks.firstIndex(where: { $0.id == blockID }),
              case let .image(pictures, caption) = blocks[index].kind
        else { return nil }

        // Reuse a row somebody opened and left empty rather than stacking
        // another blank one under it.
        if let blank = pictures.first(where: { $0.src.isEmpty }) {
            return blank.id
        }

        let picture = Block.Picture()
        blocks[index].kind = .image(pictures: pictures + [picture], caption: caption)
        return picture.id
    }

    /// Called when the uploader's jobs change. Anything finished is written
    /// into the block it belongs to and then forgotten.
    func absorbUploads() {
        let uploader = MediaUploader.shared

        for job in uploader.jobs {
            guard let target = uploadTargets[job.id] else { continue }

            switch job.state {
            case .uploading:
                continue

            case let .finished(url):
                apply(url, to: target)
                uploadTargets.removeValue(forKey: job.id)
                uploader.clear(job.id)

            case let .failed(message):
                failure = message
                uploadTargets.removeValue(forKey: job.id)
                uploader.clear(job.id)
            }
        }
    }

    /// The progress of whichever upload is filling this picture, if any.
    func uploadProgress(forPicture pictureID: UUID) -> Double? {
        guard let jobID = uploadTargets.first(where: { key, value in
            if case let .picture(_, picture) = value, picture == pictureID { return true }
            return false
        })?.key else { return nil }

        return MediaUploader.shared.job(jobID)?.progress
    }

    private func apply(_ url: String, to target: Target) {
        switch target {
        case let .picture(blockID, pictureID):
            guard let index = blocks.firstIndex(where: { $0.id == blockID }),
                  case var .image(pictures, caption) = blocks[index].kind,
                  let at = pictures.firstIndex(where: { $0.id == pictureID })
            else { return }
            pictures[at].src = url
            blocks[index].kind = .image(pictures: pictures, caption: caption)

        case let .videoSource(blockID):
            guard let index = blocks.firstIndex(where: { $0.id == blockID }),
                  case let .video(_, poster, caption) = blocks[index].kind else { return }
            blocks[index].kind = .video(src: url, poster: poster, caption: caption)

        case let .videoPoster(blockID):
            guard let index = blocks.firstIndex(where: { $0.id == blockID }),
                  case let .video(src, _, caption) = blocks[index].kind else { return }
            blocks[index].kind = .video(src: src, poster: url, caption: caption)

        case let .file(blockID):
            guard let index = blocks.firstIndex(where: { $0.id == blockID }),
                  case let .file(_, name) = blocks[index].kind else { return }
            blocks[index].kind = .file(src: url, name: name.isEmpty ? (url as NSString).lastPathComponent : name)
        }
    }

    var hasUploadsInFlight: Bool {
        !uploadTargets.isEmpty
    }

    // MARK: - Saving

    func save(using client: BroadsideClient?) async -> Post? {
        guard let client else {
            failure = APIError.notSignedIn.errorDescription
            return nil
        }

        isSaving = true
        defer { isSaving = false }

        var post = original
        post.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        post.body = BlockDocument.serialize(blocks)
        post.slug = slug.trimmingCharacters(in: .whitespaces)
        post.summary = summary
        post.draft = isDraft
        post.published = published
        post.tags = tags
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        do {
            if isNew {
                return try await client.create(PostSubmission(from: post))
            }
            // The slug is the address of an existing post, so the update is
            // sent to the slug it had rather than to the one being set.
            return try await client.update(slug: original.slug, with: PostSubmission(from: post))
        } catch {
            failure = describe(error)
            return nil
        }
    }

    private func describe(_ error: any Error) -> String {
        guard let api = error as? APIError else { return error.localizedDescription }
        if let suggestion = api.recoverySuggestion {
            return (api.errorDescription ?? "") + "\n\n" + suggestion
        }
        return api.errorDescription ?? error.localizedDescription
    }
}
