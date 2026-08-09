import SwiftUI

/// The block editor.
///
/// Movable stacks, the same idea as the web editor and the same closed set of
/// block types, but built for a thumb rather than a mouse. Reordering is a
/// long-press drag on the list rather than a pair of arrow buttons, the type
/// picker is a menu on the row itself, and there is no drag handle to hit
/// because the whole row is the handle.
struct EditorView: View {
    @Environment(AccountStore.self) private var account
    @Environment(\.dismiss) private var dismiss

    @State private var model: EditorModel
    @State private var showingDetails = false
    @State private var showingDiscardWarning = false

    private let onSaved: (Post) -> Void

    init(post: Post, onSaved: @escaping (Post) -> Void) {
        _model = State(initialValue: EditorModel(post: post))
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Title", text: $model.title, axis: .vertical)
                        .font(.title2.weight(.semibold))
                        .textInputAutocapitalization(.sentences)
                }

                Section {
                    ForEach($model.blocks) { $block in
                        BlockRow(block: $block, model: model)
                            .contextMenu { menu(for: block) }
                    }
                    .onMove { model.move(from: $0, to: $1) }
                    .onDelete { model.remove(at: $0) }
                } footer: {
                    addButton
                }
            }
            .listStyle(.plain)
            .environment(\.editMode, .constant(.inactive))
            .navigationTitle(model.title.isEmpty ? "New post" : model.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .sheet(isPresented: $showingDetails) {
                PostDetailsView(model: model)
            }
            .onChange(of: MediaUploader.shared.jobs.map(\.state)) {
                model.absorbUploads()
            }
            .alert(
                "That did not work",
                isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } }),
                presenting: model.failure
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { failure in
                Text(failure)
            }
            .confirmationDialog(
                "Discard this post?",
                isPresented: $showingDiscardWarning,
                titleVisibility: .visible
            ) {
                Button("Discard changes", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            } message: {
                Text("Nothing has been sent to your server yet.")
            }
            .interactiveDismissDisabled(model.hasChanges)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
                if model.hasChanges {
                    showingDiscardWarning = true
                } else {
                    dismiss()
                }
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button("Details", systemImage: "slider.horizontal.3") {
                showingDetails = true
            }
        }

        ToolbarItem(placement: .confirmationAction) {
            if model.isSaving {
                ProgressView()
            } else {
                Button("Save", action: save).disabled(!model.canSave)
            }
        }
    }

    private var addButton: some View {
        Menu {
            ForEach(Array(Block.Kind.insertable.enumerated()), id: \.offset) { _, kind in
                Button(kind.label, systemImage: kind.symbolName) {
                    withAnimation { model.insert(kind, after: nil) }
                }
            }
        } label: {
            Label("Add a block", systemImage: "plus.circle.fill")
                .font(.body)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func menu(for block: Block) -> some View {
        Menu("Change to", systemImage: "arrow.triangle.2.circlepath") {
            ForEach(Array(Block.Kind.insertable.enumerated()), id: \.offset) { _, kind in
                Button(kind.label, systemImage: kind.symbolName) {
                    model.convert(blockID: block.id, to: kind)
                }
            }
        }

        Button("Add below", systemImage: "plus") {
            let index = model.blocks.firstIndex { $0.id == block.id }
            withAnimation { model.insert(.paragraph(text: ""), after: index) }
        }

        Button("Delete", systemImage: "trash", role: .destructive) {
            if let index = model.blocks.firstIndex(where: { $0.id == block.id }) {
                withAnimation { model.remove(at: IndexSet(integer: index)) }
            }
        }
    }

    private func save() {
        Task {
            if let saved = await model.save(using: account.client) {
                onSaved(saved)
                dismiss()
            }
        }
    }
}

/// Everything about a post that is not its words.
///
/// Behind a sheet rather than at the top of the editor, because on a phone the
/// screen is small enough that a column of metadata above the first paragraph
/// means writing starts below the fold.
private struct PostDetailsView: View {
    @Bindable var model: EditorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Draft", isOn: $model.isDraft)
                    DatePicker("Published", selection: $model.published)
                } footer: {
                    Text(footerText)
                }

                Section("Tags") {
                    TextField("astro, sv503", text: $model.tags)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    TextField("Left empty, one is taken from the opening lines", text: $model.summary, axis: .vertical)
                        .lineLimit(2...5)
                } header: {
                    Text("Summary")
                }

                Section {
                    TextField("Taken from the title", text: $model.slug)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Slug")
                } footer: {
                    Text("The last part of the post's address. Changing it on a published post breaks any link anybody already has.")
                }
            }
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var footerText: String {
        if model.isDraft {
            return "Drafts stay off the public timeline until you turn this off."
        }
        if model.published > Date() {
            return "This is in the future, so the post stays hidden until then and publishes itself."
        }
        return "This post is live."
    }
}
