import SwiftUI
import ForkyCore

struct ConflictSheet: View {
    let request: AdvancedRequest
    let file: FileChange
    let store: RepositoryStore
    @State private var review: ConflictReview?
    @State private var error: String?
    @State private var text = ""
    @State private var source = 2
    @State private var delete = false
    @State private var allowMarkers = false

    var body: some View {
        AdvancedFrame(title: "Resolve Conflict", subtitle: file.path.value + " · " + request.expected.root.lastPathComponent) {
            if let error { FeatureError(text: error) }
            else if let review {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Picker("Version", selection: $source) {
                            Text("Base").tag(1); Text("Ours · stage 2").tag(2); Text("Theirs · stage 3").tag(3)
                        }.pickerStyle(.segmented).frame(maxWidth: 400)
                        Spacer()
                        Button("Use Ours") { text = review.ours ?? ""; delete = review.ours == nil }.accessibilityIdentifier("conflictUseOurs")
                        Button("Use Theirs") { text = review.theirs ?? ""; delete = review.theirs == nil }.accessibilityIdentifier("conflictUseTheirs")
                    }.padding(10)
                    if store.editDrafts[store.conflictDraftKey(request, path: file.path)] != nil {
                        Text("A retained failed-save draft was restored. Discard it to reload the current working version.").font(.caption).foregroundStyle(.orange).padding(.horizontal, 10)
                    }
                    Text("During rebase, Ours is the new base and Theirs is the replayed commit. Use stage identities, not branch-name guesses.")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 8)
                    HSplitView {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("READ-ONLY VERSION").font(.caption2).foregroundStyle(.secondary)
                            if let version = source == 1 ? review.base : source == 2 ? review.ours : review.theirs {
                                SourceTextView(text: version, identifier: "conflictSource")
                            } else { Text("No file at this index stage (addition/deletion).").font(.callout).foregroundStyle(.secondary) }
                        }.padding(8).frame(minWidth: 220, maxWidth: .infinity, maxHeight: .infinity)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("EDITED RESULT").font(.caption2).foregroundStyle(.secondary)
                            TextEditor(text: $text).font(.system(size: 12, design: .monospaced))
                                .disabled(delete).accessibilityIdentifier("conflictResult")
                        }.padding(8).frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                    }
                    HStack {
                        Toggle("Resolve by deleting this file", isOn: $delete).accessibilityIdentifier("conflictDelete")
                        Spacer()
                        Toggle("Allow reviewed literal marker lines", isOn: $allowMarkers).font(.caption)
                    }.padding(10)
                }
            } else { ProgressView("Reading base / ours / theirs and working bytes…") }
        } actions: {
            Button("Cancel") { store.sheet = nil }.keyboardShortcut(.cancelAction)
            if store.editDrafts[store.conflictDraftKey(request, path: file.path)] != nil {
                Button("Discard Retained Draft") {
                    store.editDrafts.removeValue(forKey: store.conflictDraftKey(request, path: file.path))
                    text = review?.working ?? ""
                }
            }
            Spacer()
            Button("Save Worktree Only") { save(stage: false) }.disabled(review == nil || !store.canWrite || delete).accessibilityIdentifier("conflictSave")
            Button(delete ? "Delete & Stage Resolution" : "Save & Stage Resolution") { save(stage: true) }
                .buttonStyle(.borderedProminent).disabled(review == nil || !store.canWrite).accessibilityIdentifier("conflictStage")
        }
        .task {
            do {
                let value = try await request.repository.reviewConflict(file.path, expected: request.expected)
                try Task.checkCancellation()
                review = value
                text = store.editDrafts[store.conflictDraftKey(request, path: file.path)] ?? value.working ?? ""
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    private func save(stage: Bool) {
        guard let review else { return }
        store.saveResolution(request, review: review, text: text, delete: delete, stage: stage, allowMarkers: allowMarkers)
    }
}
