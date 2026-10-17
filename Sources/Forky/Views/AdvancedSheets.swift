import AppKit
import SwiftUI
import ForkyCore

struct AdvancedSheet: View {
    let request: AdvancedRequest
    let store: RepositoryStore
    var body: some View {
        switch request.action {
        case .partial(let file, let side): PartialSheet(request: request, file: file, side: side, store: store)
        case .discard(let file): PartialSheet(request: request, file: file, side: .worktree, store: store, discard: true)
        case .conflict(let file): ConflictSheet(request: request, file: file, store: store)
        case .commit(let action, let commit): CommitActionSheet(request: request, action: action, commit: commit, store: store)
        case .rebase(let commit): RebaseSheet(request: request, base: commit, store: store)
        case .operation: OperationSheet(request: request, store: store)
        case .tree(let commit): TreeSheet(request: request, commit: commit, store: store)
        }
    }
}

struct AdvancedFrame<Content: View, Actions: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions
    var body: some View {
        let window = NSApp.mainWindow
        let width = min(960, max(620, (window?.contentLayoutRect.width ?? 1040) - 50))
        let height = min(570, max(320, (window?.contentLayoutRect.height ?? 680) - 50))
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.title3.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            }.padding(16)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 12) { actions }.padding(14)
        }.frame(width: width, height: height)
    }
}

struct FeatureError: View {
    let text: String
    var body: some View {
        ScrollView { Text(text).font(.callout).foregroundStyle(.orange).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(16) }
    }
}

struct PartialSheet: View {
    let request: AdvancedRequest
    let file: FileChange
    let side: DiffSide
    let store: RepositoryStore
    var discard = false
    @State private var approvedDiscard = false
    @State private var review: PartialReview?
    @State private var selection = Set<Int>()
    @State private var error: String?
    var body: some View {
        AdvancedFrame(title: discard ? "Discard Working Lines / Hunks" : side == .worktree ? "Stage Lines / Hunks" : "Unstage Lines / Hunks",
                      subtitle: file.path.value + (discard ? " · Changes the working file, not the index. This is destructive." : " · Only the index changes. Worktree bytes remain untouched.")) {
            if let error { FeatureError(text: error) }
            else if let review {
                VStack(spacing: 0) {
                    HStack {
                        Text(discard ? "Worktree → index changes to discard / restore" : side == .worktree ? "Index → worktree additions/deletions" : "Index → HEAD changes to remove from staging")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Select All") { selection = review.patch.changeIDs }.accessibilityIdentifier("partialSelectAll")
                        Button("Clear") { selection = [] }
                    }.padding(10)
                    List {
                        ForEach(review.patch.hunks) { hunk in
                            Section {
                                ForEach(hunk.lines) { line in
                                    HStack(spacing: 8) {
                                        if line.isChange {
                                            Toggle("", isOn: Binding(get: { selection.contains(line.id) }, set: { if $0 { selection.insert(line.id) } else { selection.remove(line.id) } }))
                                                .labelsHidden().toggleStyle(.checkbox).accessibilityLabel("Select changed line")
                                                .accessibilityIdentifier("patchLine:\(line.id)")
                                        } else { Color.clear.frame(width: 16, height: 1) }
                                        Text((line.kind == .addition ? "+" : line.kind == .deletion ? "−" : " ") + line.text)
                                            .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                            .foregroundStyle(line.kind == .addition ? .green : line.kind == .deletion ? .red : .secondary)
                                        Spacer(minLength: 0)
                                        if line.noNewline { Text("No final newline").font(.caption2).foregroundStyle(.secondary) }
                                    }
                                }
                            } header: {
                                HStack {
                                    Text(hunk.header).font(.system(.caption, design: .monospaced))
                                    Spacer()
                                    Button("Select Hunk") { selection.formUnion(hunk.changeIDs) }.buttonStyle(.borderless)
                                        .accessibilityIdentifier("patchHunk:\(hunk.id)")
                                }
                            }
                        }
                    }.listStyle(.inset)
                }
            } else { ProgressView("Reading complete patch…") }
        } actions: {
            Button("Cancel") { store.sheet = nil }.keyboardShortcut(.cancelAction)
            Spacer()
            if discard { Toggle("Approve permanent working-file change", isOn: $approvedDiscard).font(.caption) }
            Text("\(selection.count) lines").font(.caption).foregroundStyle(.secondary)
            Button(discard ? "Discard Selection" : side == .worktree ? "Stage Selection" : "Unstage Selection") {
                guard let review else { return }
                let selected = selection, approval = approvedDiscard
                store.performAdvanced(request, title: discard ? "Discarding reviewed working changes…" : "Applying reviewed index-only patch…") { try await $0.applyPartial(review, selected: selected, approveDiscard: approval) }
            }.buttonStyle(.borderedProminent).disabled(review == nil || selection.isEmpty || !store.canWrite || (discard && !approvedDiscard))
                .accessibilityIdentifier("partialConfirm")
        }
        .task {
            do { let value = try await (discard ? request.repository.reviewDiscard(file, expected: request.expected) : request.repository.reviewPartial(file, side: side, expected: request.expected)); try Task.checkCancellation(); review = value }
            catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}

struct CommitActionSheet: View {
    let request: AdvancedRequest
    let action: CommitAction
    let commit: GitCommit
    let store: RepositoryStore
    @State private var mainline = 0
    @State private var createCommit = true
    @State private var appendSource = false
    var body: some View {
        AdvancedFrame(title: action.rawValue + " Commit", subtitle: request.expected.root.path + " · " + request.expected.branchLabel) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(commit.subject).font(.headline)
                    Text(commit.oid).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    Text(action == .cherryPick ? "Replay this commit onto the current branch, creating a commit. No checkout of its source branch." : "Create a new inverse commit on the current branch. Existing history is not reset.")
                    Text("A clean worktree is required. Conflicts pause the operation; resolve files, then Continue, Skip or Abort. Hooks and signing settings apply.")
                        .foregroundStyle(.secondary)
                    Toggle("Create commit immediately (otherwise leave staged changes)", isOn: $createCommit)
                    if action == .cherryPick { Toggle("Append original commit SHA to message", isOn: $appendSource).disabled(!createCommit) }
                    if commit.parents.count > 1 {
                        Picker("Mainline parent", selection: $mainline) {
                            Text("Choose parent explicitly").tag(0)
                            ForEach(Array(commit.parents.enumerated()), id: \.element) { index, oid in Text("Parent \(index + 1) · " + oid).tag(index + 1) }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }
        } actions: {
            Button("Cancel") { store.sheet = nil }.keyboardShortcut(.cancelAction)
            Spacer()
            Button(action.rawValue) {
                var options = CommitApplyOptions()
                options.mainline = mainline > 0 ? mainline : nil; options.createCommit = createCommit; options.appendSource = appendSource
                let captured = options
                store.performAdvanced(request, title: action.rawValue + " · " + commit.shortOID) { try await $0.applyCommit(commit, action: action, expected: request.expected, options: captured) }
            }.buttonStyle(.borderedProminent).disabled(!store.canEditHistory || (commit.parents.count > 1 && mainline == 0))
                .accessibilityIdentifier("commitActionConfirm")
        }
    }
}

struct OperationBanner: View {
    let store: RepositoryStore
    var body: some View {
        if let operation = store.snapshot?.operation, let kind = operation.kind, !store.isMutating {
            HStack {
                Label(kind == .unknown ? "Git operation state needs inspection" : kind.rawValue.capitalized + " in progress", systemImage: "exclamationmark.triangle")
                Text("\(store.snapshot?.changes.filter(\.isConflict).count ?? 0) conflicts").foregroundStyle(.secondary)
                Spacer()
                Button("Review Operation…") {
                    if kind == .bisect { store.requestManagement(.bisect) }
                    else { store.requestAdvanced(.operation) }
                }
                    .disabled(!store.canWrite || kind == .unknown).accessibilityIdentifier("reviewGitOperation")
            }.font(.callout).padding(10).background(.orange.opacity(0.08))
            Divider()
        }
    }
}
