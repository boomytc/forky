import SwiftUI
import ForkyCore

private struct BatchSelection {
    let files: [FileChange]
    let side: DiffSide
    let root: URL
}

struct ChangesView: View {
    @Bindable var store: RepositoryStore
    @State private var batch: BatchSelection?

    private var selection: Binding<ChangeSelection?> {
        Binding(get: { store.selectedChange }, set: store.selectChange)
    }
    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("Local Changes").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("\(store.snapshot?.changes.count ?? 0) \(store.snapshot?.changes.count == 1 ? "file" : "files")").font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(.horizontal, 12).frame(height: 34)
                FilterField(prompt: "Filter changed files", text: $store.fileQuery, identifier: "fileFilter")
                    .padding(.horizontal, 10).padding(.bottom, 8)
                Divider()
                if let snapshot = store.snapshot, snapshot.changes.isEmpty {
                    EmptyPane(icon: "checkmark.circle", title: "All caught up", subtitle: "Your working tree is clean.")
                } else {
                    List(selection: selection) {
                        changeSection(store.visibleUnstaged, side: .worktree)
                        changeSection(store.visibleStaged, side: .staged)
                    }
                    .listStyle(.inset).environment(\.defaultMinListRowHeight, 26)
                    .accessibilityIdentifier("changesList")
                }
                Divider()
                CommitComposer(store: store)
            }
            .frame(minWidth: 265, idealWidth: 310, maxWidth: 430)
            DiffPane(store: store).frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: store.fileQuery) { _, _ in store.fileFilterChanged() }
        .confirmationDialog(batch?.side == .worktree ? "Stage these files?" : "Unstage these files?",
                            isPresented: Binding(get: { batch != nil }, set: { if !$0 { batch = nil } }),
                            titleVisibility: .visible, presenting: batch) { request in
            Button("\(request.side == .worktree ? "Stage" : "Unstage") \(request.files.count) Files") {
                guard store.repository?.root == request.root else { return }
                if request.side == .worktree { store.stage(request.files) }
                else { store.unstage(request.files) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(request.files.prefix(5).map(\.path.value).joined(separator: "\n")
                 + (request.files.count > 5 ? "\n… and \(request.files.count - 5) more" : "")
                 + "\n\nOnly these listed paths are affected. Worktree files are not deleted.")
        }
    }

    private func changeSection(_ files: [FileChange], side: DiffSide) -> some View {
        Section {
            ForEach(files) { change in
                ChangeRow(change: change, side: side, enabled: store.canWrite,
                          root: store.repository?.root) {
                    if side == .worktree { store.stage(change) } else { store.unstage(change) }
                }
                .tag(ChangeSelection(path: change.id, side: side))
            }
        } header: {
            HStack {
                Text("\(side == .worktree ? "Unstaged" : "Staged") (\(files.count))")
                Spacer()
                Button(store.fileQuery.isEmpty ? (side == .worktree ? "Stage All" : "Unstage All") : "Apply to Filtered") {
                    if let root = store.repository?.root { batch = BatchSelection(files: files, side: side, root: root) }
                }
                .font(.system(size: 10)).buttonStyle(.borderless).textCase(nil)
                .disabled(files.isEmpty || !store.canWrite)
                .accessibilityIdentifier(side == .worktree ? "stageAll" : "unstageAll")
            }
        }
    }
}

private struct ChangeRow: View {
    let change: FileChange
    let side: DiffSide
    let enabled: Bool
    let root: URL?
    let action: () -> Void
    private var code: String { change.isConflict ? "!" : (change.isUntracked ? "?" : String(side == .staged ? change.index : change.worktree)) }
    private var color: Color { change.isConflict ? .orange : (code == "D" ? .red : (code == "A" || code == "?" ? .green : .secondary)) }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: change.isConflict ? "exclamationmark.triangle" : "doc.text")
                .foregroundStyle(.secondary).frame(width: 14)
            Text(change.path.name).font(.system(size: 12)).lineLimit(1)
            if !change.path.directory.isEmpty {
                Text(change.path.directory).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 2)
            Text(code).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(color).help(change.statusLabel)
            Button(side == .staged ? "Unstage File" : "Stage File",
                   systemImage: side == .staged ? "minus.circle" : "plus.circle", action: action)
                .labelStyle(.iconOnly).buttonStyle(.borderless).frame(width: 23, height: 23)
                .disabled(!enabled).help(side == .staged ? "Unstage this file" : "Stage this file")
                .accessibilityIdentifier("\(side == .staged ? "unstage" : "stage"):\(change.path.value)")
        }
        .padding(.vertical, 1).contentShape(.rect)
        .simultaneousGesture(TapGesture(count: 2).onEnded { if enabled { action() } })
        .help(change.originalPath.map { "\($0.value) → \(change.path.value)" } ?? change.path.value)
        .contextMenu {
            Button(side == .worktree ? "Stage File" : "Unstage File", action: action).disabled(!enabled)
            Divider()
            FileContextActions(root: root, path: change.path)
        }
    }
}

private struct CommitComposer: View {
    @Bindable var store: RepositoryStore
    private var subjectLength: Int { store.commitMessage.split(separator: "\n", omittingEmptySubsequences: false).first?.count ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Commit to \(store.snapshot?.branchLabel ?? "HEAD")", systemImage: "arrow.triangle.branch")
                    .lineLimit(1).font(.system(size: 11, weight: .medium))
                Spacer()
                Text("\(subjectLength) / 72").font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(subjectLength > 72 ? .orange : .secondary)
                    .help("Suggested summary length, not a commit limit")
            }
            TextEditor(text: $store.commitMessage)
                .font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden)
                .padding(5).frame(height: 96)
                .background(ForkyTheme.panel, in: .rect(cornerRadius: 5))
                .overlay(alignment: .topLeading) {
                    if store.commitMessage.isEmpty {
                        Text("Summary, then an optional description…").font(.system(size: 11))
                            .foregroundStyle(.tertiary).padding(.horizontal, 10).padding(.top, 12).allowsHitTesting(false)
                    }
                }
                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.separator.opacity(0.4)) }
                .disabled(store.isMutating)
                .accessibilityLabel("Commit message").accessibilityIdentifier("commitMessage")
            if let label = store.commitTemplateLabel {
                Label("Prefilled from " + label, systemImage: "doc.text")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help("From commit.template. Comment lines are removed; the editor content is what will be committed.")
                    .accessibilityIdentifier("commitTemplateSource")
            }
            if let note = store.commitCompositionNote {
                Label(note, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2)
            }
            Toggle("Sign off (Signed-off-by)", isOn: Binding(get: { store.commitSignOff }, set: store.updateCommitSignOff))
                .toggleStyle(.checkbox).font(.system(size: 11))
                .disabled(store.isMutating)
                .help("Git appends a Signed-off-by line from your configured identity. The choice is remembered for this repository.")
                .accessibilityIdentifier("commitSignOff")
            if store.snapshot?.operationInProgress == true || store.snapshot?.hasConflicts == true {
                Label("Resolve the current Git operation or conflicts first.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            Button(action: store.commit) {
                HStack {
                    Image(systemName: "checkmark")
                    Text("Commit Staged")
                    Text("(\(store.snapshot?.staged.count ?? 0))").foregroundStyle(.secondary)
                    Spacer()
                    Text("⌘↩").font(.system(size: 11))
                }.frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.regular)
            .disabled(!store.canCommit).accessibilityIdentifier("commitStaged")
            Text("Only staged files · Git hooks and signing settings apply")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(12)
            .task(id: store.repository?.root.path ?? "") { await store.prepareCommitComposition() }
    }
}
