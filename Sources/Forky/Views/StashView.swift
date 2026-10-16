import SwiftUI
import ForkyCore

struct StashView: View {
    @Bindable var store: RepositoryStore
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Stashes", systemImage: "archivebox").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Save Stash…", systemImage: "plus") { store.requestStash(.save) }
                    .disabled(!store.canUseTools || store.snapshot?.head == nil || store.snapshot?.changes.isEmpty != false)
                    .accessibilityIdentifier("saveStash")
            }.padding(.horizontal, 12).frame(height: 40)
            Divider()
            if let error = store.snapshot?.collaboration.error {
                EmptyPane(icon: "exclamationmark.triangle", title: "Stash list unavailable", subtitle: error)
            } else if store.tools?.stashes.isEmpty == true {
                EmptyPane(icon: "archivebox", title: "A safe place for unfinished work",
                          subtitle: "Save local changes without committing. Applying a stash keeps its recovery entry until you explicitly drop it.")
            } else {
                HSplitView {
                    List(selection: Binding(get: { store.selectedStashID }, set: store.selectStash)) {
                        ForEach(store.tools?.stashes ?? []) { stash in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(stash.subject).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                HStack {
                                    Text(stash.selector).font(.system(size: 10, design: .monospaced))
                                    Spacer()
                                    Text(stash.date, style: .date).font(.system(size: 10))
                                }.foregroundStyle(.secondary)
                            }.padding(.vertical, 5).tag(stash.id).accessibilityIdentifier("stash:" + stash.oid)
                        }
                    }.listStyle(.inset).frame(minWidth: 200, idealWidth: 260, maxWidth: 360)
                    VStack(spacing: 0) {
                        if let stash = store.selectedStash {
                            HStack {
                                Text(String(stash.oid.prefix(8))).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                                Spacer()
                                Button("Apply…") { store.requestStash(.apply(stash)) }
                                    .disabled(!store.canUseTools).accessibilityIdentifier("applyStash")
                                Button("Drop…") { store.requestStash(.drop(stash)) }
                                    .disabled(!store.canUseTools).accessibilityIdentifier("dropStash")
                            }.padding(.horizontal, 12).frame(height: 36)
                            Divider()
                        }
                        DiffPane(store: store)
                    }
                }
            }
        }
    }
}

struct StashSheet: View {
    let request: StashRequest
    let store: RepositoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var includeUntracked = false
    @State private var restoreIndex = true

    private var title: String {
        switch request.action { case .save: "Save Stash"; case .apply: "Apply Stash"; case .drop: "Drop Stash" }
    }
    private var dirtyApply: Bool {
        if case .apply = request.action { return !request.expected.changes.isEmpty }
        return false
    }
    private var blocked: Bool {
        if case .save = request.action {
            return request.expected.head == nil || request.expected.changes.isEmpty
                || request.expected.hasConflicts || request.expected.operationInProgress
                || (!includeUntracked && request.expected.changes.allSatisfy(\.isUntracked))
        }
        return dirtyApply || request.expected.hasConflicts || request.expected.operationInProgress
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Label(title, systemImage: "archivebox").font(.title3.weight(.semibold))
            Text(request.expected.root.lastPathComponent + "  /  " + request.expected.branchLabel).font(.callout).foregroundStyle(.secondary)
            switch request.action {
            case .save:
                TextField("Optional message", text: $message).accessibilityIdentifier("stashMessage")
                Toggle("Include untracked files", isOn: $includeUntracked).accessibilityIdentifier("stashIncludeUntracked")
                Text("Save tracked staged and unstaged changes, then remove those changes from the worktree. Untracked files stay unless explicitly included; ignored files stay.")
                    .font(.callout).foregroundStyle(.secondary)
            case .apply(let stash):
                Text(stash.subject).font(.headline)
                Toggle("Restore the staged / unstaged split", isOn: $restoreIndex)
                Text("Apply the reviewed stash to this branch. The stash is kept, including after a conflict. Conflicts require editing the affected files and staging the resolution.")
                    .font(.callout).foregroundStyle(.secondary)
            case .drop(let stash):
                Text(stash.subject).font(.headline)
                Label("Remove this recovery entry permanently from the stash list. Working files will not change. This does not apply it first.",
                      systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
            }
            if blocked {
                Text(dirtyApply ? "Commit or stash local changes before applying." : "No eligible changes, or a conflict / Git operation needs attention.")
                    .font(.callout).foregroundStyle(.orange)
            }
            Text("Git filters may run. An error is not a rollback; Forky checks repository state after every attempt.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(title) {
                    store.performStash(request, message: message, includeUntracked: includeUntracked, restoreIndex: restoreIndex)
                    dismiss()
                }.buttonStyle(.borderedProminent).tint(title == "Drop Stash" ? .red : ForkyTheme.accent)
                    .disabled(!store.canUseTools || blocked).accessibilityIdentifier("stashConfirm")
            }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 450)
    }
}
