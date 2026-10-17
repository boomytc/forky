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
    @State private var document: ConflictDocument?
    @State private var choices: [Int: ConflictChoice] = [:]
    @State private var chunkError: String?
    @State private var activeChunk: Int?
    @State private var bulkChoice: ConflictChoice?
    @State private var showChunks = true
    @State private var confirmTool = false

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
                    if let document, !document.chunks.isEmpty {
                        VStack(spacing: 6) {
                            chunkNavigation(document)
                            DisclosureGroup(isExpanded: $showChunks) {
                                ScrollViewReader { proxy in
                                    ScrollView {
                                        LazyVStack(spacing: 2) {
                                            ForEach(document.chunks) { chunk in chunkRow(chunk) }
                                        }
                                    }.frame(maxHeight: 132)
                                    .onChange(of: activeChunk) { _, value in
                                        guard let value else { return }
                                        withAnimation { proxy.scrollTo(value, anchor: .center) }
                                    }
                                }
                                HStack(spacing: 8) {
                                    Button("All Ours") { bulkChoice = .ours }.accessibilityIdentifier("conflictAllOurs")
                                    Button("All Theirs") { bulkChoice = .theirs }.accessibilityIdentifier("conflictAllTheirs")
                                    Spacer()
                                    Button("Replace Editor with These Chunk Choices") { text = document.render(choices) }
                                        .help("Explicitly replaces manual edits with this generated result. Unselected chunks keep original markers.")
                                        .accessibilityIdentifier("conflictApplyChunks")
                                }
                            } label: {
                                Text("Choose each side · \(document.chunks.count) chunks").font(.caption)
                            }
                        }.padding(.horizontal, 10)
                    }
                    if let chunkError { Text(chunkError).font(.caption).foregroundStyle(.orange).padding(.horizontal, 10) }
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
            Button("Configured Mergetool…") { confirmTool = true }
                .disabled(review == nil || !store.canWrite || text != (review?.working ?? ""))
                .help("Runs trusted Git-configured code; may modify and stage this file. Review tool configuration first.")
            Button("Save Worktree Only") { save(stage: false) }.disabled(review == nil || !store.canWrite || delete).accessibilityIdentifier("conflictSave")
            Button(delete ? "Delete & Stage Resolution" : "Save & Stage Resolution") { save(stage: true) }
                .buttonStyle(.borderedProminent).disabled(review == nil || !store.canWrite).accessibilityIdentifier("conflictStage")
        }
        .confirmationDialog(bulkChoice == .ours ? "Set every chunk to Ours?" : "Set every chunk to Theirs?",
                            isPresented: Binding(get: { bulkChoice != nil }, set: { if !$0 { bulkChoice = nil } }),
                            titleVisibility: .visible, presenting: bulkChoice) { choice in
            Button(choice == .ours ? "Set All to Ours" : "Set All to Theirs") {
                guard let document else { return }
                choices = document.choices(choice)
            }.accessibilityIdentifier("conflictBulkConfirm")
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This changes chunk choices only. Press Replace Editor with These Chunk Choices to apply them; nothing is staged.")
        }
        .confirmationDialog("Run the Git-configured mergetool?", isPresented: $confirmTool) {
            Button("Run Configured Tool") {
                guard let review else { return }
                store.performAdvanced(request, title: "Running explicitly configured mergetool…") { try await $0.runMergetool(review) }
            }
        } message: { Text("This executes trusted Git-configured code and may modify/stage this file. Save or discard manual editor edits first. No tool is installed.") }
        .task {
            do {
                let value = try await request.repository.reviewConflict(file.path, expected: request.expected)
                try Task.checkCancellation()
                review = value
                do { document = try ConflictDocument(value.working ?? "") } catch { chunkError = error.localizedDescription }
                text = store.editDrafts[store.conflictDraftKey(request, path: file.path)] ?? value.working ?? ""
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    private func save(stage: Bool) {
        guard let review else { return }
        store.saveResolution(request, review: review, text: text, delete: delete, stage: stage, allowMarkers: allowMarkers)
    }
    private func positionLabel(_ document: ConflictDocument) -> String {
        let progress = document.progress(choices)
        guard let activeChunk, let index = document.chunks.firstIndex(where: { $0.id == activeChunk }) else {
            return "\(progress.resolved) of \(progress.total) chunks resolved"
        }
        return "Chunk \(index + 1) of \(document.chunks.count) · \(progress.resolved) resolved"
    }
    private func chunkNavigation(_ document: ConflictDocument) -> some View {
        let progress = document.progress(choices)
        return HStack(spacing: 8) {
            Text(positionLabel(document)).font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("conflictChunkProgress")
            Spacer()
            Button("Previous Unresolved") { jumpUnresolved(in: document, forward: false) }
                .disabled(progress.unresolved == 0).accessibilityIdentifier("conflictPreviousChunk")
            Button("Next Unresolved") { jumpUnresolved(in: document, forward: true) }
                .disabled(progress.unresolved == 0).accessibilityIdentifier("conflictNextChunk")
        }
    }
    private func jumpUnresolved(in document: ConflictDocument, forward: Bool) {
        let target = forward ? document.nextUnresolvedID(after: activeChunk, choices: choices)
                             : document.previousUnresolvedID(before: activeChunk, choices: choices)
        if let target { activeChunk = target }
    }
    private func chunkRow(_ chunk: ConflictChunk) -> some View {
        let choice = choices[chunk.id] ?? .unresolved
        let current = activeChunk == chunk.id
        return HStack(spacing: 6) {
            Image(systemName: choice == .unresolved ? "circle" : "checkmark.circle.fill")
                .foregroundStyle(choice == .unresolved ? Color.secondary : Color.green)
            Text("Chunk \(chunk.id + 1)").font(.caption).fontWeight(current ? .semibold : .regular)
            if current { Text("current").font(.caption2).foregroundStyle(.secondary) }
            Spacer()
            Picker("Choice", selection: Binding(get: { choice }, set: { choices[chunk.id] = $0; activeChunk = chunk.id })) {
                ForEach(ConflictChoice.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.labelsHidden().frame(maxWidth: 150)
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
        .background(current ? Color.accentColor.opacity(0.12) : .clear, in: .rect(cornerRadius: 4))
        .contentShape(.rect)
        .onTapGesture { activeChunk = chunk.id }
        .id(chunk.id)
    }
}
