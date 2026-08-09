import SwiftUI

/// One block, drawn according to what it is.
///
/// Every case is a small editor bound straight into the block, so typing
/// updates the model rather than a copy that has to be reconciled later. That
/// matters more than it sounds: the failure mode of the alternative is losing
/// the last sentence somebody typed because the save ran before the commit.
struct BlockRow: View {
    @Binding var block: Block
    let model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch block.kind {
            case let .paragraph(text):
                TextField(
                    "Write here. Markdown works inline.",
                    text: binding(get: { text }, set: { .paragraph(text: $0) }),
                    axis: .vertical
                )
                .textInputAutocapitalization(.sentences)

            case let .heading(level, text):
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Menu("H\(level)") {
                        ForEach(2...4, id: \.self) { option in
                            Button("Heading \(option)") {
                                block.kind = .heading(level: option, text: text)
                            }
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)

                    TextField(
                        "Heading",
                        text: binding(get: { text }, set: { .heading(level: level, text: $0) }),
                        axis: .vertical
                    )
                    .font(headingFont(for: level))
                }

            case let .quote(text):
                HStack(spacing: 10) {
                    Rectangle()
                        .fill(.tertiary)
                        .frame(width: 3)
                    TextField(
                        "Quote",
                        text: binding(get: { text }, set: { .quote(text: $0) }),
                        axis: .vertical
                    )
                    .italic()
                }

            case let .code(language, text):
                VStack(alignment: .leading, spacing: 6) {
                    TextField(
                        "Language, optional",
                        text: binding(get: { language }, set: { .code(language: $0, text: text) })
                    )
                    .font(.caption)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    TextField(
                        "Code",
                        text: binding(get: { text }, set: { .code(language: language, text: $0) }),
                        axis: .vertical
                    )
                    .font(.system(.callout, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                }

            case let .bulleted(items):
                ListItemsEditor(items: items, marker: { _ in "•" }) { updated in
                    block.kind = .bulleted(items: updated)
                }

            case let .numbered(items):
                ListItemsEditor(items: items, marker: { "\($0 + 1)." }) { updated in
                    block.kind = .numbered(items: updated)
                }

            case .image:
                PictureBlockView(block: $block, model: model)

            case let .video(src, poster, caption):
                MediaFieldsEditor(
                    fields: [
                        .init(label: "Video path", value: src) { block.kind = .video(src: $0, poster: poster, caption: caption) },
                        .init(label: "Poster image, optional", value: poster) { block.kind = .video(src: src, poster: $0, caption: caption) },
                        .init(label: "Caption, optional", value: caption, isPath: false) { block.kind = .video(src: src, poster: poster, caption: $0) },
                    ]
                )

            case let .file(src, name):
                MediaFieldsEditor(
                    fields: [
                        .init(label: "File path", value: src) { block.kind = .file(src: $0, name: name) },
                        .init(label: "Name shown to readers", value: name, isPath: false) { block.kind = .file(src: src, name: $0) },
                    ]
                )

            case let .embed(url, title):
                MediaFieldsEditor(
                    fields: [
                        .init(label: "https://…", value: url) { block.kind = .embed(url: $0, title: title) },
                        .init(label: "Link text, optional", value: title, isPath: false) { block.kind = .embed(url: url, title: $0) },
                    ]
                )

            case .divider:
                HStack {
                    VStack { Divider() }
                    Text("Divider")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    VStack { Divider() }
                }
                .padding(.vertical, 6)

            case let .raw(text):
                VStack(alignment: .leading, spacing: 6) {
                    Label("Markdown this editor does not model. It is kept exactly as written.", systemImage: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    TextField(
                        "Markdown",
                        text: binding(get: { text }, set: { .raw(text: $0) }),
                        axis: .vertical
                    )
                    .font(.system(.callout, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// Bridges a `TextField` to one associated value of the block's enum.
    ///
    /// The kinds carry their contents rather than the block having a bag of
    /// optional properties, which keeps an image block from having a `language`
    /// and a code block from having an `alt`. The cost is this shim, and it is
    /// worth paying once here rather than making every state in the app
    /// nullable.
    private func binding(get: @escaping () -> String, set: @escaping (String) -> Block.Kind) -> Binding<String> {
        Binding(get: get, set: { block.kind = set($0) })
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 2: .title2.weight(.semibold)
        case 3: .title3.weight(.semibold)
        default: .headline
        }
    }
}

/// The rows of a bulleted or numbered list.
private struct ListItemsEditor: View {
    let items: [String]
    let marker: (Int) -> String
    let onChange: ([String]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(marker(index))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 18, alignment: .trailing)

                    TextField("List item", text: Binding(
                        get: { item },
                        set: { newValue in
                            var updated = items
                            updated[index] = newValue
                            onChange(updated)
                        }
                    ), axis: .vertical)

                    if items.count > 1 {
                        Button("Remove", systemImage: "minus.circle") {
                            var updated = items
                            updated.remove(at: index)
                            onChange(updated)
                        }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.tertiary)
                        .buttonStyle(.plain)
                    }
                }
            }

            Button("Add item", systemImage: "plus") {
                onChange(items + [""])
            }
            .font(.caption)
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .padding(.leading, 26)
        }
    }
}

/// A stack of plain text fields, for the blocks that are only paths and labels.
private struct MediaFieldsEditor: View {
    struct Field {
        let label: String
        let value: String
        var isPath: Bool = true
        let onChange: (String) -> Void
    }

    let fields: [Field]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                TextField(field.label, text: Binding(get: { field.value }, set: field.onChange))
                    .font(field.isPath ? .system(.callout, design: .monospaced) : .callout)
                    .textInputAutocapitalization(field.isPath ? .never : .sentences)
                    .autocorrectionDisabled(field.isPath)
            }
        }
    }
}
