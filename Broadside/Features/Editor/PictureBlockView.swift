import SwiftUI
import PhotosUI

/// The picture block: one photograph, or several, in which case it is a
/// gallery.
///
/// There is no separate gallery block to choose. Adding a second picture is
/// what makes it one, and removing the second turns it back, which is the same
/// rule the web editor follows and the same rule the file format encodes.
struct PictureBlockView: View {
    @Binding var block: Block
    let model: EditorModel

    @Environment(AccountStore.self) private var account
    @State private var selection: [PhotosPickerItem] = []
    @State private var isImporting = false

    private var pictures: [Block.Picture] {
        if case let .image(pictures, _) = block.kind { return pictures }
        return []
    }

    private var caption: String {
        if case let .image(_, caption) = block.kind { return caption }
        return ""
    }

    private var isGallery: Bool { pictures.count > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(pictures.enumerated()), id: \.element.id) { index, picture in
                PictureRow(
                    picture: picture,
                    index: index,
                    total: pictures.count,
                    progress: model.uploadProgress(forPicture: picture.id),
                    imageURL: account.client?.absoluteURL(for: picture.src),
                    onChange: { updated in replace(at: index, with: updated) },
                    onRemove: { remove(at: index) },
                    onMoveEarlier: index > 0 ? { move(from: index, to: index - 1) } : nil,
                    onMoveLater: index < pictures.count - 1 ? { move(from: index, to: index + 1) } : nil
                )
            }

            HStack(spacing: 12) {
                PhotosPicker(
                    selection: $selection,
                    // No cap. Somebody adding a night's worth of frames should
                    // not have to come back and do it in batches of five.
                    maxSelectionCount: nil,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    Label(
                        pictures.contains(where: { !$0.src.isEmpty }) ? "Add pictures" : "Choose pictures",
                        systemImage: "photo.badge.plus"
                    )
                    .font(.callout)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)

                if isImporting {
                    ProgressView().controlSize(.small)
                }

                Spacer()
            }

            TextField(
                isGallery ? "Caption for the gallery, optional" : "Caption, optional",
                text: Binding(
                    get: { caption },
                    set: { block.kind = .image(pictures: pictures, caption: $0) }
                )
            )
            .font(.callout)
        }
        .onChange(of: selection) { _, items in
            guard !items.isEmpty else { return }
            importPictures(items)
        }
    }

    // MARK: - Importing

    /// Copies each chosen photograph out of the library and hands it to the
    /// background uploader.
    ///
    /// One at a time rather than all at once. Twenty parallel exports from the
    /// photo library on a phone is how the app gets killed for memory, and the
    /// sequence also means the slides end up in the order they were picked.
    private func importPictures(_ items: [PhotosPickerItem]) {
        guard let client = account.client else { return }

        isImporting = true

        Task {
            for item in items {
                guard let picked = try? await item.loadTransferable(type: PickedFile.self) else { continue }
                guard let pictureID = model.appendPicture(to: block.id) else { continue }

                model.startPictureUpload(
                    file: picked.url,
                    filename: picked.filename,
                    contentType: picked.contentType,
                    into: block.id,
                    picture: pictureID,
                    using: client
                )
            }

            selection = []
            isImporting = false
        }
    }

    // MARK: - Editing the set

    private func replace(at index: Int, with picture: Block.Picture) {
        var updated = pictures
        guard updated.indices.contains(index) else { return }
        updated[index] = picture
        block.kind = .image(pictures: updated, caption: caption)
    }

    private func remove(at index: Int) {
        var updated = pictures
        guard updated.indices.contains(index) else { return }
        updated.remove(at: index)
        if updated.isEmpty { updated = [Block.Picture()] }
        block.kind = .image(pictures: updated, caption: caption)
    }

    private func move(from: Int, to: Int) {
        var updated = pictures
        guard updated.indices.contains(from), updated.indices.contains(to) else { return }
        let picture = updated.remove(at: from)
        updated.insert(picture, at: to)
        block.kind = .image(pictures: updated, caption: caption)
    }
}

/// One picture in the block.
private struct PictureRow: View {
    let picture: Block.Picture
    let index: Int
    let total: Int
    let progress: Double?
    let imageURL: URL?

    let onChange: (Block.Picture) -> Void
    let onRemove: () -> Void
    let onMoveEarlier: (() -> Void)?
    let onMoveLater: (() -> Void)?

    private var isGallery: Bool { total > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                thumbnail

                VStack(alignment: .leading, spacing: 6) {
                    if isGallery {
                        Text("Picture \(index + 1) of \(total)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    TextField("Description for screen readers", text: Binding(
                        get: { picture.alt },
                        set: { var updated = picture; updated.alt = $0; onChange(updated) }
                    ), axis: .vertical)
                    .font(.callout)

                    // Only in a gallery. On a single picture the block's own
                    // caption field below covers it, and two boxes meaning the
                    // same thing is worse than one.
                    if isGallery {
                        TextField("Caption for this picture, optional", text: Binding(
                            get: { picture.caption },
                            set: { var updated = picture; updated.caption = $0; onChange(updated) }
                        ))
                        .font(.caption)
                    }
                }
            }

            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
            } else if picture.src.isEmpty {
                TextField("Or paste a path", text: Binding(
                    get: { picture.src },
                    set: { var updated = picture; updated.src = $0; onChange(updated) }
                ))
                .font(.system(.caption, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }

            if isGallery {
                HStack(spacing: 14) {
                    Button("Move earlier", systemImage: "arrow.left") { onMoveEarlier?() }
                        .disabled(onMoveEarlier == nil)
                    Button("Move later", systemImage: "arrow.right") { onMoveLater?() }
                        .disabled(onMoveLater == nil)
                    Spacer()
                    Button("Remove", systemImage: "trash", role: .destructive, action: onRemove)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .padding(isGallery ? 10 : 0)
        .background(isGallery ? AnyShapeStyle(.quaternary.opacity(0.4)) : AnyShapeStyle(.clear))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var thumbnail: some View {
        Group {
            if let imageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    case .failure:
                        Image(systemName: "photo.badge.exclamationmark")
                            .foregroundStyle(.tertiary)
                    default:
                        ProgressView().controlSize(.small)
                    }
                }
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 64, height: 64)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
