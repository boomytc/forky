import SwiftUI
import ForkyCore

enum RefEditMode: String, CaseIterable { case rename = "Rename Branch / Tag", delete = "Delete Ref", tag = "Create Tag", remoteURL = "Edit Remote URL", remotePushURL = "Edit Remote Push URL", removeRemote = "Remove Remote", renameRemote = "Rename Remote", upstream = "Set Upstream", clearUpstream = "Clear Upstream" }

struct ManagementSheet: View {
    let request: ManagementRequest
    let store: RepositoryStore
    var body: some View {
        if request.initialTool == .images { ImageComparisonSheet(request: request, store: store) }
        else if request.initialTool == .integrate { IntegrationSheet(request: request, store: store) }
        else if request.initialTool == .reset { ResetSheet(request: request, store: store) }
        else if request.initialTool.isBasic { BasicManagementSheet(request: request, store: store) }
        else { ExtendedManagementSheet(request: request, store: store) }
    }
}

struct BasicManagementSheet: View {
    let request: ManagementRequest
    let store: RepositoryStore
    @State private var tool: ManagementTool
    @State private var editMode = RefEditMode.rename
    @State private var selectedRef = ""
    @State private var selectedRemote = ""
    @State private var name = ""
    @State private var message = ""
    @State private var annotated = false
    @State private var includeStaged = false
    @State private var approved = false
    @State private var mergeMode = MergeMode.fastForward
    @State private var failure: String?
    init(request: ManagementRequest, store: RepositoryStore) {
        self.request = request; self.store = store
        _tool = State(initialValue: request.initialTool)
    }
    private var refs: [GitReference] { request.expected.references.filter { $0.symbolicTarget == nil } }
    private var remotes: [GitRemote] { request.expected.collaboration.value?.remotes ?? [] }
    private var ref: GitReference? { refs.first { $0.id == selectedRef } }
    private var remote: GitRemote? { remotes.first { $0.id == selectedRemote } }
    var body: some View {
        AdvancedFrame(title: tool.rawValue, subtitle: request.expected.root.path + " · " + request.expected.branchLabel) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Workflow", selection: $tool) {
                        ForEach(ManagementTool.allCases.filter(\.isBasic)) { Text($0.rawValue).tag($0) }
                    }.accessibilityIdentifier("managementWorkflow")
                    switch tool {
                    case .amend:
                        Text("Replace HEAD " + (request.expected.head ?? "(no commit)")).font(.system(.caption, design: .monospaced))
                        TextEditor(text: $message).font(.system(.body, design: .monospaced)).frame(minHeight: 150).accessibilityIdentifier("amendMessage")
                        Toggle("Include explicitly staged changes (otherwise change message only)", isOn: $includeStaged)
                            .accessibilityIdentifier("amendIncludeStaged")
                        Text("\(request.expected.staged.count) staged files. Unstaged files are never added. Hooks and configured signing remain effective.")
                    case .references: referenceForm
                    case .worktrees, .settings, .stash, .sync, .patches, .submodules, .lfs, .bisect, .external, .images, .reset, .integrate, .gitflow: EmptyView()
                    case .merge:
                        referencePicker
                        Picker("Merge mode", selection: $mergeMode) {
                            ForEach(MergeMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.accessibilityIdentifier("mergeMode")
                        Text("Source: " + (ref?.commitOID ?? "Select a commit-bearing reference")).font(.system(.caption, design: .monospaced))
                        Text("Destination: " + (request.expected.head ?? "(unborn)") + "\nA clean worktree is required. No autostash. Conflicts pause for the existing resolution workflow. Squash leaves staged changes for a normal commit.")
                    }
                    if let failure { Text(failure).foregroundStyle(.orange).textSelection(.enabled) }
                    Toggle("I reviewed the target and effects. Changes may already be applied if Git fails or is cancelled.", isOn: $approved)
                        .accessibilityIdentifier("managementApprove")
                }.padding(18)
            }
        } actions: {
            Button("Cancel") { store.sheet = nil }.keyboardShortcut(.cancelAction)
            Spacer()
            Button("Apply Reviewed Action", action: perform)
                .buttonStyle(.borderedProminent).disabled(!approved || !store.canWrite || !valid)
                .accessibilityIdentifier("managementConfirm")
        }
        .task(id: tool) {
            guard tool == .amend, message.isEmpty, let head = request.expected.head else { return }
            do {
                let commit = try await request.repository.commitInfo(head)
                try Task.checkCancellation()
                message = commit.subject + (commit.body.isEmpty ? "" : "\n\n" + commit.body)
            } catch is CancellationError {} catch { failure = error.localizedDescription }
        }
        .onChange(of: tool) { _, _ in approved = false; failure = nil }
        .onChange(of: editMode) { _, _ in approved = false }
        .onChange(of: selectedRef) { _, _ in approved = false }
        .onChange(of: selectedRemote) { _, _ in approved = false }
        .onChange(of: name) { _, _ in approved = false }
        .onChange(of: message) { _, _ in approved = false }
        .onChange(of: includeStaged) { _, _ in approved = false }
        .onChange(of: mergeMode) { _, _ in approved = false }
        .onChange(of: annotated) { _, _ in approved = false }
    }
    private var referencePicker: some View {
        Picker("Reference", selection: $selectedRef) {
            Text("Choose a reference").tag("")
            ForEach(refs) { Text($0.fullName).tag($0.id) }
        }.accessibilityIdentifier("managementReference")
    }
    private var referenceForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Action", selection: $editMode) { ForEach(RefEditMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .accessibilityIdentifier("referenceEditMode")
            if [.remoteURL, .remotePushURL, .removeRemote, .renameRemote].contains(editMode) {
                Picker("Remote", selection: $selectedRemote) {
                    Text("Choose a remote").tag("")
                    ForEach(remotes) { Text($0.name + " · " + ($0.fetchURLs.first.map(TransportPresentation.display) ?? "")).tag($0.id) }
                }
            } else if editMode != .tag && editMode != .clearUpstream { referencePicker }
            if [.rename, .tag, .remoteURL, .remotePushURL, .renameRemote].contains(editMode) {
                TextField([.remoteURL, .remotePushURL].contains(editMode) ? "New URL" : "New name", text: $name).textFieldStyle(.roundedBorder).accessibilityIdentifier("referenceNewName")
            }
            if editMode == .tag {
                Text("Target: " + (request.commitOID ?? "(no commit)")).font(.system(.caption, design: .monospaced))
                Toggle("Annotated tag (otherwise explicitly lightweight, unsigned)", isOn: $annotated)
                if annotated { TextField("Annotation", text: $message).textFieldStyle(.roundedBorder) }
            }
            Text("Deleting a branch never forces unmerged history or another worktree's checkout. Editing a URL changes the first fetch URL only; additional fetch/push URLs stay configured. Removing a remote also removes its local tracking refs/config, not server data. Remote-branch deletion is not a local ref deletion.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var valid: Bool {
        switch tool {
        case .amend: request.expected.head != nil && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .merge: ref?.commitOID != nil
        case .worktrees, .settings, .stash, .sync, .patches, .submodules, .lfs, .bisect, .external, .images, .reset, .integrate, .gitflow: false
        case .references:
            switch editMode {
            case .rename: ref != nil && ref?.kind != .remoteBranch && !name.isEmpty
            case .delete: ref != nil && ref?.kind != .remoteBranch
            case .tag: request.commitOID != nil && !name.isEmpty && (!annotated || !message.isEmpty)
            case .remoteURL, .remotePushURL, .renameRemote: remote != nil && !name.isEmpty
            case .removeRemote: remote != nil
            case .upstream: ref != nil && ref?.kind != .tag
            case .clearUpstream: request.expected.branch != nil
            }
        }
    }
    private func perform() {
        guard FormEditing.finish() else { approved = false; failure = FormEditing.reviewMessage; return }
        guard approved else { return }
        let expected = request.expected
        switch tool {
        case .amend:
            let message = message, staged = includeStaged
            store.performManagement(request, title: "Amending reviewed HEAD…") { try await $0.amend(message: message, includeStaged: staged, expected: expected) }
        case .merge:
            guard let oid = ref?.commitOID else { return }
            let mode = mergeMode
            store.performManagement(request, title: "Merging reviewed source…") { try await $0.merge(oid, mode: mode, expected: expected) }
        case .worktrees, .settings, .stash, .sync, .patches, .submodules, .lfs, .bisect, .external, .images, .reset, .integrate, .gitflow: return
        case .references:
            let action: ReferenceChange
            switch editMode {
            case .rename: guard let ref else { return }; action = .rename(ref, name)
            case .delete: guard let ref else { return }; action = .delete(ref)
            case .tag: guard let oid = request.commitOID else { return }; action = .tag(name: name, oid: oid, message: annotated ? message : nil)
            case .remoteURL: guard let remote else { return }; action = .remoteURL(remote, name)
            case .remotePushURL: guard let remote else { return }; action = .remotePushURL(remote, name)
            case .clearUpstream: action = .upstream(nil)
            case .removeRemote: guard let remote else { return }; action = .removeRemote(remote)
            case .renameRemote: guard let remote else { return }; action = .renameRemote(remote, name)
            case .upstream: action = .upstream(ref)
            }
            store.performManagement(request, title: editMode.rawValue + "…") { try await $0.changeReference(action, expected: expected) }
        }
    }
}
