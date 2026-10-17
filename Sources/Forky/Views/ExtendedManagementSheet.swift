import SwiftUI
import ForkyCore

struct ExtendedManagementSheet: View {
    let request: ManagementRequest
    let store: RepositoryStore
    @State private var action = ""
    @State private var value = ""
    @State private var second = ""
    @State private var message = ""
    @State private var input = ""
    @State private var argv = "[]"
    @State private var remoteID = ""
    @State private var stashID = ""
    @State private var worktreeID = ""
    @State private var setting = "user.name"
    @State private var inherit = false
    @State private var includeUntracked = false
    @State private var restoreIndex = false
    @State private var selectedFiles = Set<String>()
    @State private var selectedRefs = Set<String>()
    @State private var selectedRemotes = Set<String>()
    @State private var worktrees: [GitWorktree] = []
    @State private var settings: [GitSetting] = []
    @State private var patch: PatchImport?
    @State private var output = ""
    @State private var failure: String?
    @State private var busy = false
    @State private var approved = false
    @State private var loadID = UUID()
    @State private var openID = UUID()
    @State private var openRequested = false
    private var tool: ManagementTool { request.initialTool }
    private var metadata: CollaborationSnapshot? { request.expected.collaboration.value }
    private var remotes: [GitRemote] { metadata?.remotes ?? [] }
    private var stash: GitStash? { metadata?.stashes.first { $0.id == stashID } }
    private var remote: GitRemote? { remotes.first { $0.id == remoteID } }
    private var variants: [String] {
        switch tool {
        case .worktrees: ["List", "Create", "Remove"]
        case .settings: ["Inspect", "Set Local", "Use Git Executable"]
        case .stash: ["Selected Files", "Rename", "Pop"]
        case .sync: ["Fetch Selected Remotes", "Push Selected Branches / Tags"]
        case .patches: ["Review Text Patch", "Export Commit"]
        case .submodules: ["Status", "Add", "Update"]
        case .lfs: ["Status", "Locks", "Track", "Fetch", "Pull", "Lock", "Unlock"]
        case .gitflow: GitflowTask.allCases.map(\.rawValue)
        case .bisect: ["Log", "Start", "Good", "Bad", "Skip", "Reset"]
        case .external: ["Custom Tool", "AI Draft", "Gitflow / Lean Branching"]
        default: []
        }
    }
    private var fingerprint: String {
        [action, value, second, message, input, argv, remoteID, stashID, worktreeID, setting,
         String(inherit), String(includeUntracked), String(restoreIndex),
         selectedFiles.sorted().joined(separator: "\0"), selectedRefs.sorted().joined(separator: "\0"),
         selectedRemotes.sorted().joined(separator: "\0")].joined(separator: "\u{1f}")
    }
    var body: some View {
        AdvancedFrame(title: tool.rawValue, subtitle: request.expected.root.path + " · " + request.expected.branchLabel) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Action", selection: $action) { ForEach(variants, id: \.self) { Text($0).tag($0) } }
                        .accessibilityIdentifier("extendedAction")
                    fields
                    HStack {
                        Button("Inspect / Preview") { loadID = UUID() }.disabled(busy)
                        if busy { ProgressView().controlSize(.small) }
                    }
                    if let failure { Text(failure).foregroundStyle(.orange).textSelection(.enabled) }
                    if !output.isEmpty {
                        SourceTextView(text: output, identifier: "toolPreview").frame(height: 155)
                    }
                    if let previous = store.lastToolOutput {
                        DisclosureGroup("Last completed tool result") {
                            SourceTextView(text: previous, identifier: "lastToolResult").frame(height: 170)
                            if tool == .external && action == "AI Draft" {
                                Button("Replace Current Draft with Tool Output (does not commit)") {
                                    store.commitMessage = store.lastToolBody ?? ""
                                }
                            }
                        }
                    }
                    Toggle("I reviewed this action, exact inputs and affected scope. Network / configured code runs only on Apply. Errors are not rollback.", isOn: $approved)
                        .accessibilityIdentifier("extendedApprove")
                }.padding(18)
            }
        } actions: {
            Button("Close") { store.sheet = nil }.keyboardShortcut(.cancelAction)
            Spacer()
            Button("Apply Reviewed Action", action: perform).buttonStyle(.borderedProminent)
                .disabled(!approved || busy || !store.canWrite || isReadOnly || !validInputs).accessibilityIdentifier("extendedConfirm")
        }
        .task { action = variants.first ?? ""; loadID = UUID() }
        .task(id: loadID) { await inspect() }
        .task(id: openID) {
            guard openRequested else { return }
            do {
                let url = try await request.repository.submoduleDirectory(GitPath(value), expected: request.expected)
                try Task.checkCancellation()
                guard store.repository?.root == request.expected.root else { throw GitError.staleRepository }
                store.sheet = nil; store.open(url)
            } catch is CancellationError {} catch { failure = error.localizedDescription }
        }
        .onChange(of: fingerprint) { _, _ in approved = false }
        .onChange(of: value) { _, _ in patch = nil }
        .onChange(of: action) { _, _ in
            patch = nil; failure = nil; approved = false
            if tool == .settings {
                if action == "Use Git Executable" { value = store.gitExecutablePath; second = store.explicitHelperPATH }
                else { let local = settings.first { $0.key == setting }?.local; value = local ?? ""; inherit = local == nil }
            }
        }
        .onChange(of: setting) { _, key in
            let observed = settings.first { $0.key == key }; value = observed?.local ?? ""; inherit = observed?.local == nil
        }
    }
    private var validInputs: Bool {
        switch tool {
        case .worktrees: return action == "Create" ? value.hasPrefix("/") && request.commitOID != nil : worktrees.contains { $0.id == worktreeID }
        case .settings: return action == "Use Git Executable" ? value.hasPrefix("/") : inherit || !value.isEmpty
        case .stash:
            if action == "Selected Files" {
                return !selectedFiles.isEmpty && selectedFiles.allSatisfy { id in request.expected.changes.contains { $0.id == id && !$0.isConflict && (includeUntracked || !$0.isUntracked) } }
            }
            return stash != nil && (action == "Pop" || !message.isEmpty)
        case .sync: return action == "Fetch Selected Remotes" ? !selectedRemotes.isEmpty : remote != nil && !selectedRefs.isEmpty
        case .patches: return action == "Export Commit" ? value.hasPrefix("/") && request.commitOID != nil : patch != nil
        case .submodules: return !value.isEmpty && (action != "Add" || !second.isEmpty)
        case .lfs: return ["Fetch", "Pull"].contains(action) ? remote != nil : ["Track", "Lock", "Unlock"].contains(action) ? !value.isEmpty : true
        case .bisect: return action == "Start" ? !value.isEmpty && !second.isEmpty : request.expected.operation.kind == .bisect
        case .gitflow: return !(GitflowTask(rawValue: action)?.requiresName ?? true) || !value.isEmpty
        case .external: return value.hasPrefix("/") && argv.utf8.count <= 65536 && input.utf8.count <= 4 * 1024 * 1024
        default: return false
        }
    }
    private var isReadOnly: Bool {
        (tool == .worktrees && action == "List") || (tool == .settings && action == "Inspect") ||
        (tool == .submodules && action == "Status") || (tool == .lfs && action == "Status") ||
        (tool == .bisect && action == "Log") || (tool == .gitflow && action == "Version")
    }
    @ViewBuilder private var fields: some View {
        switch tool {
        case .worktrees:
            if action == "Create" {
                AbsolutePathField(title: "New absolute directory (choose existing parent)", value: $value, selection: .newDirectory)
                textField("New branch name; blank = detached", text: $second)
                Text("Start commit: " + (request.commitOID ?? "(none)")).font(.caption)
                Text("A failed addition retains its new directory. No existing path is adopted.")
            } else {
                Picker("Worktree", selection: $worktreeID) {
                    Text("Choose worktree").tag("")
                    ForEach(worktrees) { Text($0.root.path + ($0.locked ? " · locked" : "")).tag($0.id) }
                }
                Text("Removal deletes this worktree directory through native Git. Current, dirty, locked and ignored-data worktrees refuse; no force removal.")
            }
        case .settings:
            if action == "Use Git Executable" {
                AbsolutePathField(title: "Absolute trusted Git executable", value: $value, selection: .executable)
                textField("Explicit helper PATH (blank inherits; absolute dirs separated by :)", text: $second)
                Text("Current: " + store.gitExecutablePath + ". Applies after reopening this tab; other tabs keep their selected executable. This runs caller-selected code; no installation.")
            } else {
                Picker("Setting", selection: $setting) { ForEach(GitRepository.editableSettings, id: \.self) { Text($0).tag($0) } }
                textField("Local value", text: $value)
                Toggle("Remove local override / inherit existing configuration", isOn: $inherit)
                Text("Effective: " + (settings.first { $0.key == setting }?.effective ?? "(unset)"))
                Text("Only this local key changes. An owner-only backup of the original local config is retained; it can contain private configuration. Helpers/SSH remain existing Git configuration.")
            }
        case .stash:
            if action == "Selected Files" {
                Toggle("Include selected untracked files (never ignored files)", isOn: $includeUntracked)
                ForEach(request.expected.changes) { file in
                    check(file.path.value, id: file.id, selection: $selectedFiles)
                        .disabled(file.isConflict || (file.isUntracked && !includeUntracked))
                }
            } else {
                Picker("Stash", selection: $stashID) {
                    Text("Choose stash").tag("")
                    ForEach(metadata?.stashes ?? []) { Text($0.selector + " · " + $0.subject).tag($0.id) }
                }
                if action == "Pop" { Toggle("Restore index separation", isOn: $restoreIndex); Text("Apply first; drop only on success with the unchanged reviewed list. Conflicts keep the stash.") }
            }
            if action != "Pop" { textField("Message / new name", text: $message) }
        case .sync:
            if action == "Fetch Selected Remotes" {
                ForEach(remotes) { check($0.name + " · " + ($0.fetchURLs.first.map(TransportPresentation.display) ?? ""), id: $0.id, selection: $selectedRemotes) }
            } else {
                remotePicker
                ForEach(request.expected.references.filter { $0.kind != .remoteBranch && $0.symbolicTarget == nil }) {
                    check($0.fullName + " · " + String($0.objectOID.prefix(8)), id: $0.id, selection: $selectedRefs)
                }
                Text("Only these immutable OID → exact refspecs are sent. No force, mirror or automatic tags. A server may accept some refs and reject others; there is no rollback.")
            }
            Text("For divergent pull: Fetch, then explicitly review Merge or Interactive Rebase against the refreshed tracking ref. No automatic stash/rewrite.")
        case .patches:
            AbsolutePathField(title: action == "Export Commit" ? "New absolute output filename" : "Absolute input patch filename", value: $value, selection: action == "Export Commit" ? .outputFile : .inputFile)
            Text(action == "Export Commit" ? "Captured commit: " + (request.commitOID ?? "(none)") : "Inspect freezes a ≤4 MiB text patch and checks index + worktree applicability. Apply rechecks. No binary expansion or unsafe paths. Requires clean state.")
        case .submodules:
            textField("Repository-relative submodule path", text: $value)
            Button("Open Verified Submodule") { openRequested = true; openID = UUID() }.disabled(value.isEmpty || busy)
            if action != "Status" {
                if action == "Add" { textField("Source URL / absolute local source", text: $second) }
                Text("Network may occur. Add stages .gitmodules/gitlink by native Git. Update uses no force/recursive/remote flag; dirty submodules may refuse.")
            }
        case .lfs:
            if ["Track", "Lock", "Unlock"].contains(action) { textField("Repository-relative filename", text: $value) }
            if ["Fetch", "Pull"].contains(action) { remotePicker }
            Text("Bring your own git-lfs on PATH. Locks/Fetch/Pull/Lock/Unlock may contact the configured server. Track edits .gitattributes but does not stage it. Nothing is installed.")
        case .gitflow:
            if GitflowTask(rawValue: action)?.requiresName == true { textField("Feature / release / hotfix name", text: $value) }
            Text("Existing git-flow on the selected Git PATH only; never installed. Initialization accepts that plugin’s default branch/config names. Finish can checkout, merge, tag and modify several refs/configs, run hooks or contact services according to plugin settings. Review its configuration first. Failures are not rollback.")
                .foregroundStyle(.orange)
        case .bisect:
            if action == "Start" {
                textField("Known good commit OID", text: $value); textField("Known bad commit OID", text: $second)
            }
            Text("Current HEAD: " + (request.expected.head ?? "(none)") + ". Native bisect can checkout another commit. Up to 200 candidate commits are reviewed for ignored obstructions. Reset returns to the captured original branch/commit; it is not a general undo.")
        case .external:
            AbsolutePathField(title: "Absolute trusted executable", value: $value, selection: .executable)
            Text("JSON argument array. {input_file} is replaced as one argv value, never a shell expression.")
            TextEditor(text: $argv).font(.system(.caption, design: .monospaced)).frame(height: 65)
            if action == "AI Draft" {
                Text("Inspect loads only the reviewed staged diff. Your selected tool may transmit it, read other files or change state. No bundled agent/prompt or credentials are used. Output is a proposal, never an automatic commit.")
            } else if action == "Gitflow / Lean Branching" {
                Text("Bring your own trusted Gitflow/branching command. Example argv for a selected git executable: [\"flow\",\"feature\",\"start\",\"name\"]. Review all checkout/stash/tag/push side effects yourself; this is not sandboxed and installs nothing.")
            }
            TextEditor(text: $input).font(.system(.caption, design: .monospaced)).frame(height: 100)
            Text("This is unrestricted user-selected code, not a sandbox. It may access files, network, hooks and credentials beyond this repository. Direct child cancellation is not descendant containment.")
                .foregroundStyle(.orange)
        default: EmptyView()
        }
    }
    private func textField(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text).textFieldStyle(.roundedBorder)
    }
    private func check(_ title: String, id: String, selection: Binding<Set<String>>) -> some View {
        Toggle(title, isOn: Binding(get: { selection.wrappedValue.contains(id) }, set: {
            if $0 { selection.wrappedValue.insert(id) } else { selection.wrappedValue.remove(id) }
        })).toggleStyle(.checkbox)
    }
    private var remotePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Remote", selection: $remoteID) {
                Text("Choose remote").tag("")
                ForEach(remotes) { Text($0.name).tag($0.id) }
            }
            if let remote { RemoteScopeView(remote: remote) }
        }
    }
    private func inspect() async {
        busy = true; failure = nil
        do {
            let text: String
            switch tool {
            case .worktrees:
                let list = try await request.repository.worktrees()
                try Task.checkCancellation(); worktrees = list
                text = list.map { $0.root.path + " · " + ($0.branch ?? "detached") }.joined(separator: "\n")
            case .settings:
                let list = try await request.repository.settings()
                try Task.checkCancellation(); settings = list
                text = list.map { $0.key + " = " + ($0.effective ?? "(unset)") + ($0.local == nil ? " (inherited)" : " (local)") }.joined(separator: "\n")
            case .patches:
                if action != "Review Text Patch" || value.isEmpty { busy = false; return }
                let review = try await request.repository.reviewPatch(at: (try LocalFilePath.absolute(value)), expected: request.expected)
                try Task.checkCancellation(); patch = review; text = review.preview
            case .submodules: text = try await request.repository.submoduleStatus()
            case .lfs:
                if action == "Status" { text = try await request.repository.lfs(.status, expected: request.expected) }
                else if action == "Locks" { failure = "Locks is a network action: approve and use Apply to query."; busy = false; return }
                else { text = "Review the specific LFS action and scope before Apply." }
            case .gitflow:
                if action == "Version" { text = try await request.repository.gitflow(.version, name: "", expected: request.expected) }
                else { text = "No Gitflow mutation ran. Review the plugin task and affected branches/configuration." }
            case .bisect:
                if request.expected.operation.kind == .bisect { text = try await request.repository.bisectLog() }
                else { text = "No active bisect. Choose known good/bad commits to start." }
            case .external:
                if action == "AI Draft" {
                    let context = try await request.repository.stagedReviewContext(expected: request.expected)
                    try Task.checkCancellation(); input = context
                    text = "Input loaded below. Read it before approving your external agent."
                } else { text = "No command ran. Review the executable and JSON argv." }
            default: text = "Review the captured repository, selected paths/refspecs and operation above."
            }
            try Task.checkCancellation(); output = text; busy = false
        } catch is CancellationError {} catch { failure = error.localizedDescription; busy = false }
    }
    private func perform() {
        guard FormEditing.finish() else { approved = false; failure = FormEditing.reviewMessage; return }
        guard approved else { return }
        let expected = request.expected, action = action, value = value, second = second
        let message = message, include = includeUntracked, restore = restoreIndex
        do {
            switch tool {
            case .settings:
                if action == "Use Git Executable" { store.useGitExecutable(value, helperPATH: second); return }
                let changes = [setting: inherit ? nil : Optional(value)]
                run("Updating local configuration") { try await $0.updateSettings(changes, expected: expected).path }
            case .worktrees:
                if action == "Create" {
                    guard let oid = request.commitOID else { throw GitError.invalidInput("Select a starting commit.") }
                    run("Creating reviewed worktree") { repo in try await repo.addWorktree(at: (try LocalFilePath.absolute(value)), oid: oid, branch: second.isEmpty ? nil : second, expected: expected); return value }
                } else {
                    guard let worktree = worktrees.first(where: { $0.id == worktreeID }) else { throw GitError.invalidInput("Inspect and select a worktree.") }
                    run("Removing reviewed worktree") { repo in try await repo.removeWorktree(worktree, expected: expected); return worktree.root.path }
                }
            case .stash:
                if action == "Selected Files" {
                    let paths = try selectedFiles.map(GitPath.init)
                    run("Stashing selected files") { repo in try await repo.saveSelectedStash(paths: paths, message: message, includeUntracked: include, expected: expected); return "Selected paths saved; inspect refreshed state." }
                } else {
                    guard let stash else { throw GitError.invalidInput("Select a stash.") }
                    if action == "Rename" { run("Renaming stash") { repo in try await repo.renameStash(stash, message: message, expected: expected); return "Recovery entry renamed." } }
                    else { run("Applying then dropping stash") { repo in try await repo.applyStash(stash, restoreIndex: restore, expected: expected, dropAfterSuccess: true); return "Apply succeeded and reviewed entry was dropped." } }
                }
            case .sync:
                if action == "Fetch Selected Remotes" {
                    let selected = remotes.filter { selectedRemotes.contains($0.id) }
                    run("Fetching selected remotes") { repo in try await repo.fetchRemotes(selected, expected: expected); return "Fetch completed without prune/tags/submodule recursion." }
                } else {
                    guard let remote else { throw GitError.invalidInput("Choose a remote.") }
                    let refs = expected.references.filter { selectedRefs.contains($0.id) }
                    run("Pushing selected immutable refs") { repo in try await repo.pushReferences(refs, remote: remote, expected: expected); return "Selected refs pushed; inspect remote results." }
                }
            case .patches:
                if action == "Export Commit" {
                    guard let oid = request.commitOID else { throw GitError.invalidInput("Select a commit.") }
                    run("Exporting commit patch") { repo in try await repo.exportPatch(oid: oid, to: (try LocalFilePath.absolute(value))); return value }
                } else {
                    guard let patch else { throw GitError.invalidInput("Inspect and approve the exact patch first.") }
                    run("Applying reviewed text patch") { repo in try await repo.applyPatch(patch); return "Patch applied to index and worktree." }
                }
            case .submodules:
                let path = try GitPath(value)
                if action == "Add" { run("Adding submodule (network)") { repo in try await repo.addSubmodule(url: second, path: path, expected: expected); return "Inspect .gitmodules and staged gitlink." } }
                else { run("Updating submodule (network)") { repo in try await repo.updateSubmodule(path, expected: expected); return "Submodule update completed." } }
            case .lfs:
                let task: LFSTask
                switch action {
                case "Locks": task = .locks
                case "Track": task = .track(try GitPath(value))
                case "Lock": task = .lock(try GitPath(value))
                case "Unlock": task = .unlock(try GitPath(value))
                case "Fetch", "Pull":
                    guard let remote else { throw GitError.invalidInput("Choose a remote.") }
                    task = action == "Fetch" ? .fetch(remote) : .pull(remote)
                default: task = .status
                }
                run("Git LFS " + action) { try await $0.lfs(task, expected: expected) }
            case .gitflow:
                guard let task = GitflowTask(rawValue: action) else { throw GitError.invalidInput("Choose a named Gitflow task.") }
                run("Gitflow " + action) { try await $0.gitflow(task, name: value, expected: expected) }
            case .bisect:
                if action == "Start" { run("Starting reviewed bisect") { try await $0.startBisect(good: value, bad: second, expected: expected) } }
                else {
                    guard let step = BisectStep(rawValue: action.lowercased()) else { throw GitError.invalidInput("Choose a bisect step.") }
                    run("Bisect " + action) { try await $0.stepBisect(step, expected: expected) }
                }
            case .external:
                let args = try JSONDecoder().decode([String].self, from: Data(argv.utf8)), payload = input
                run("Running explicitly trusted tool") { try await $0.runTrustedTool(executable: (try LocalFilePath.absolute(value)), arguments: args, input: payload, expected: expected) }
            default: break
            }
        } catch { failure = error.localizedDescription }
    }
    private func run(_ title: String, operation: @escaping @Sendable (GitRepository) async throws -> String) {
        store.performTool(request, title: title, operation: operation)
    }
}
