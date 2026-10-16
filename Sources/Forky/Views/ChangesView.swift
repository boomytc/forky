import SwiftUI
import ForkyCore

struct ChangesView: View {
    @Bindable var store: RepositoryStore

    private var selection: Binding<ChangeSelection?> {
        Binding(get: { store.selectedChange }, set: store.selectChange)
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("Working Changes").font(.headline)
                    Spacer()
                    Text("\(store.snapshot?.changes.count ?? 0)").foregroundStyle(.secondary).monospacedDigit()
                }.padding(16)
                Divider()
                if let snapshot = store.snapshot, snapshot.changes.isEmpty {
                    EmptyPane(icon: "checkmark.circle", title: "All caught up", subtitle: "Your working tree is clean.")
                } else {
                    List(selection: selection) {
                        if let snapshot = store.snapshot {
                            Section("Unstaged · \(snapshot.unstaged.count)") {
                                ForEach(snapshot.unstaged) { change in
                                    ChangeRow(change: change, side: .worktree, enabled: store.canWrite) { store.stage(change) }
                                        .tag(ChangeSelection(path: change.id, side: .worktree))
                                }
                            }
                            Section("Staged · \(snapshot.staged.count)") {
                                ForEach(snapshot.staged) { change in
                                    ChangeRow(change: change, side: .staged, enabled: store.canWrite) { store.unstage(change) }
                                        .tag(ChangeSelection(path: change.id, side: .staged))
                                }
                            }
                        }
                    }.listStyle(.inset).accessibilityIdentifier("changesList")
                }
                Divider()
                CommitComposer(store: store)
            }
            .frame(minWidth: 265, idealWidth: 310, maxWidth: 440)
            DiffPane(store: store)
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ChangeRow: View {
    let change: FileChange
    let side: DiffSide
    let enabled: Bool
    let action: () -> Void

    private var color: Color { change.isConflict ? .orange : (change.isUntracked ? ForkyTheme.accent : .secondary) }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: change.isConflict ? "exclamationmark.triangle" : "doc.text")
                .foregroundStyle(color).frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(change.path.name).lineLimit(1)
                if !change.path.directory.isEmpty {
                    Text(change.path.directory).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            Text(change.isConflict ? "!" : (change.isUntracked ? "?" : String(side == .staged ? change.index : change.worktree)))
                .font(.system(.caption, design: .monospaced)).foregroundStyle(color)
                .help(change.statusLabel)
            Button(side == .staged ? "Unstage File" : "Stage File",
                   systemImage: side == .staged ? "minus.circle" : "plus.circle",
                   action: action)
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .disabled(!enabled)
                .help(side == .staged ? "Unstage this file" : "Stage this file")
                .accessibilityIdentifier("\(side == .staged ? "unstage" : "stage"):\(change.path.value)")
        }
        .padding(.vertical, 5)
        .help(change.originalPath.map { "\($0.value) → \(change.path.value)" } ?? change.path.value)
    }
}

private struct CommitComposer: View {
    @Bindable var store: RepositoryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("COMMIT").font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary)
                Spacer()
                Text("\(store.snapshot?.staged.count ?? 0) staged").font(.caption).foregroundStyle(.secondary)
            }
            TextEditor(text: $store.commitMessage)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(7)
                .frame(height: 86)
                .background(ForkyTheme.panel, in: .rect(cornerRadius: 7))
                .overlay(alignment: .topLeading) {
                    if store.commitMessage.isEmpty {
                        Text("Summarize your changes…").foregroundStyle(.tertiary).padding(.horizontal, 12).padding(.top, 15)
                            .allowsHitTesting(false)
                    }
                }
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.separator.opacity(0.4)) }
                .disabled(store.isMutating)
                .accessibilityLabel("Commit message").accessibilityIdentifier("commitMessage")
            if store.snapshot?.operationInProgress == true {
                Label("Finish the ongoing Git operation in another client.", systemImage: "pause.circle")
                    .font(.caption).foregroundStyle(.orange)
            } else if store.snapshot?.hasConflicts == true {
                Label("Resolve and stage conflicts before committing.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            Button(action: store.commit) {
                HStack {
                    Image(systemName: "checkmark")
                    Text("Commit Staged")
                    Spacer()
                    Text("⌘↩").foregroundStyle(.white.opacity(0.7))
                }.frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(!store.canCommit).accessibilityIdentifier("commitStaged")
            Text("Commits only the index. Configured Git hooks and signing tools may run.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(14)
    }
}
