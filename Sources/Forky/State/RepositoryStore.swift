import AppKit
import Foundation
import Observation
import ForkyCore

enum NavigationSection: Hashable {
    case changes, history, stashes, reference(String)
    var isHistory: Bool { switch self { case .history, .reference: true; default: false } }
    var ref: String? { if case .reference(let value) = self { value } else { nil } }
}

struct ChangeSelection: Hashable {
    let path: String
    let side: DiffSide
}

struct AppNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct BranchRequest: Identifiable {
    let id = UUID()
    let expected: RepositorySnapshot
    let startingOID: String
    let destination: GitReference?
    let suggestedName: String
}

@MainActor @Observable
final class RepositoryStore {
    private(set) var repository: GitRepository?
    private(set) var snapshot: RepositorySnapshot?
    private(set) var section: NavigationSection = .changes
    private(set) var selectedChange: ChangeSelection?
    private(set) var selectedCommitID: String?
    private(set) var selectedCommitFileID: String?
    private(set) var commits: [GitCommit] = []
    private(set) var commitFiles: [CommitFile] = []
    private(set) var hasMoreHistory = false
    private(set) var graph = CommitGraph.empty
    private(set) var decorations: [String: [GitReference]] = [:]
    var historyQuery = ""
    var referenceQuery = ""
    var fileQuery = ""
    var diffMode = DiffMode.unified
    var sheet: WorkspaceSheet?
    private(set) var selectedStashID: String?
    private(set) var operations: [OperationRecord] = []
    private(set) var operationPhase = OperationPhase.idle
    private(set) var cancellationRequested = false
    private(set) var diff = DiffDocument.empty
    private(set) var diffError: String?
    private(set) var historyError: String?
    private(set) var isLoading = false
    private(set) var isRefreshing = false
    private(set) var isLoadingDetail = false
    private(set) var isLoadingHistory = false
    var isMutating: Bool { operationPhase != .idle }
    private(set) var snapshotIsCurrent = false
    private(set) var activity = "Ready"
    private(set) var recentPaths: [String] = []
    var commitMessage = ""
    var notice: AppNotice?

    @ObservationIgnored private var sessionID = UUID()
    @ObservationIgnored private var refreshID = UUID()
    @ObservationIgnored private var detailID = UUID()
    @ObservationIgnored private var historyID = UUID()
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    @ObservationIgnored private var mutationTask: Task<Void, Never>?
    @ObservationIgnored private var runningLifecycle: WriteLifecycle?
    @ObservationIgnored private var bootstrapped = false
    @ObservationIgnored private var historyCursor: HistoryCursor?
    @ObservationIgnored private var drafts: [String: String] = [:]
    @ObservationIgnored private let testing = ProcessInfo.processInfo.arguments.contains("--ui-testing")

    init() {
        if !testing { recentPaths = UserDefaults.standard.stringArray(forKey: "recentRepositories") ?? [] }
    }

    var isBusy: Bool { isLoading || isRefreshing || isMutating }
    var canWrite: Bool { repository != nil && snapshotIsCurrent && !isBusy }
    var canCommit: Bool {
        canWrite && !(snapshot?.staged.isEmpty ?? true) && !(snapshot?.hasConflicts ?? true)
        && !(snapshot?.operationInProgress ?? true)
        && !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var selectedCommit: GitCommit? { commits.first { $0.id == selectedCommitID } }
    var diffTitle: String? {
        switch section {
        case .changes: selectedChange?.path
        case .stashes: selectedStash.map { "Stash · " + $0.selector }
        case .history, .reference: commitFiles.first { $0.id == selectedCommitFileID }?.path.value
        }
    }

    func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--repository"), index + 1 < args.count {
            open(URL(fileURLWithPath: args[index + 1], isDirectory: true))
        }
    }

    func chooseRepository() {
        guard !isMutating else { return }
        let panel = NSOpenPanel()
        panel.title = "Open a Git repository"
        panel.prompt = "Open Repository"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.open(url) }
        }
    }

    func open(_ url: URL) {
        guard !isMutating else { return }
        openTask?.cancel()
        cancelReads()
        sessionID = UUID()
        let session = sessionID
        isLoading = true
        isRefreshing = false
        isLoadingDetail = false
        isLoadingHistory = false
        activity = "Opening repository…"
        openTask = Task {
            do {
                let repository = try await GitRepository.open(url)
                let snapshot = try await repository.snapshot()
                try Task.checkCancellation()
                guard sessionID == session else { return }
                if let previous = self.repository { drafts[previous.root.path] = commitMessage }
                self.repository = repository
                self.snapshot = snapshot
                snapshotIsCurrent = true
                section = .changes
                commits = []; commitFiles = []; selectedCommitID = nil; selectedCommitFileID = nil
                selectedChange = nil; diff = .empty; diffError = nil; historyError = nil
                commitMessage = drafts[repository.root.path] ?? ""
                historyQuery = ""; referenceQuery = ""; fileQuery = ""
                graph = .empty; decorations = [:]; historyCursor = nil; hasMoreHistory = false
                selectedStashID = nil
                remember(repository.root)
                isLoading = false
                activity = "Ready"
                selectDefaultChange()
            } catch is CancellationError {
                if sessionID == session { isLoading = false; activity = "Ready" }
            } catch {
                guard sessionID == session else { return }
                isLoading = false
                activity = "Could not open repository"
                show(error, title: "Could not open repository")
            }
        }
    }

    func refresh() {
        guard let repository, !isMutating, !isLoading else { return }
        refreshTask?.cancel()
        let id = UUID(); refreshID = id
        let session = sessionID
        isRefreshing = true
        activity = "Refreshing…"
        refreshTask = Task {
            do {
                let value = try await repository.snapshot()
                try Task.checkCancellation()
                guard sessionID == session, refreshID == id else { return }
                snapshot = value; snapshotIsCurrent = true
                isRefreshing = false; activity = "Ready"
                reloadSelection()
            } catch is CancellationError {
                if refreshID == id { isRefreshing = false }
            } catch {
                guard sessionID == session, refreshID == id else { return }
                isRefreshing = false; snapshotIsCurrent = false
                activity = "Refresh failed"
                show(error, title: "Could not refresh repository")
            }
        }
    }

    func navigate(_ value: NavigationSection) {
        guard !isMutating, section != value else { return }
        section = value
        historyTask?.cancel(); historyID = UUID(); isLoadingHistory = false
        detailTask?.cancel(); detailID = UUID(); isLoadingDetail = false
        diff = .empty; diffError = nil
        reloadSelection()
    }

    func selectChange(_ value: ChangeSelection?) {
        selectedChange = value
        loadChangeDiff()
    }

    var visibleUnstaged: [FileChange] { (snapshot?.unstaged ?? []).filter(matchesFileFilter) }
    var visibleStaged: [FileChange] { (snapshot?.staged ?? []).filter(matchesFileFilter) }
    private func matchesFileFilter(_ change: FileChange) -> Bool {
        fileQuery.isEmpty || change.path.value.localizedStandardContains(fileQuery)
    }
    func fileFilterChanged() { selectDefaultChange() }

    private func selectDefaultChange() {
        if let selectedChange,
           let file = snapshot?.changes.first(where: { $0.id == selectedChange.path }), matchesFileFilter(file),
           selectedChange.side == .staged ? file.isStaged : file.isUnstaged {
            loadChangeDiff()
        } else if let file = visibleUnstaged.first {
            selectChange(.init(path: file.id, side: .worktree))
        } else if let file = visibleStaged.first {
            selectChange(.init(path: file.id, side: .staged))
        } else { selectChange(nil) }
    }

    private func loadChangeDiff() {
        detailTask?.cancel(); detailID = UUID()
        diff = .empty; diffError = nil; isLoadingDetail = false
        guard let repository, let selection = selectedChange,
              let change = snapshot?.changes.first(where: { $0.id == selection.path }) else { return }
        let id = detailID
        isLoadingDetail = true
        detailTask = Task {
            do {
                let text = try await repository.diff(change, side: selection.side)
                let document = await Task.detached { DiffDocument(text: text) }.value
                try Task.checkCancellation()
                guard detailID == id else { return }
                diff = document; isLoadingDetail = false
            } catch is CancellationError {
                if detailID == id { isLoadingDetail = false }
            } catch {
                guard detailID == id else { return }
                diffError = error.localizedDescription; isLoadingDetail = false
            }
        }
    }

    func loadHistory(append: Bool = false, debounce: Bool = false) {
        guard let repository, !isMutating, section.isHistory else { return }
        if append && (isLoadingHistory || historyCursor == nil) { return }
        historyTask?.cancel(); historyID = UUID()
        let id = historyID, session = sessionID
        let cursor = append ? historyCursor : nil
        let previousSelection = selectedCommitID
        let previousCommits = append ? commits : []
        let ref = section.ref
        let query = historyQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !append {
            commits = []; graph = .empty; decorations = [:]; hasMoreHistory = false; historyCursor = nil
            selectCommit(nil)
        }
        isLoadingHistory = true; historyError = nil
        historyTask = Task {
            do {
                if debounce { try await Task.sleep(for: .milliseconds(280)) }
                let page = try await repository.history(ref: ref, query: query, cursor: cursor)
                let values = previousCommits + page.commits
                let layout = await Task.detached { query.isEmpty ? CommitGraph(commits: values) : .empty }.value
                try Task.checkCancellation()
                guard historyID == id, sessionID == session else { return }
                commits = values; graph = layout
                var refsByCommit: [String: [GitReference]] = [:]
                for reference in page.references {
                    if let oid = reference.commitOID, reference.symbolicTarget == nil { refsByCommit[oid, default: []].append(reference) }
                }
                decorations = refsByCommit
                historyCursor = page.nextCursor
                hasMoreHistory = page.hasMore; isLoadingHistory = false
                if !append {
                    let selected = commits.first { $0.id == previousSelection } ?? commits.first
                    selectCommit(selected?.id)
                }
            } catch is CancellationError {
                if historyID == id { isLoadingHistory = false }
            } catch {
                guard historyID == id, sessionID == session else { return }
                historyError = error.localizedDescription; isLoadingHistory = false
            }
        }
    }

    func selectCommit(_ id: String?) {
        guard section.isHistory else { return }
        selectedCommitID = id
        commitFiles = []; selectedCommitFileID = nil
        detailTask?.cancel(); detailID = UUID()
        diff = .empty; diffError = nil; isLoadingDetail = false
        guard let repository, let commit = selectedCommit else { return }
        let token = detailID
        isLoadingDetail = true
        detailTask = Task {
            do {
                let files = try await repository.files(in: commit)
                try Task.checkCancellation()
                guard detailID == token else { return }
                commitFiles = files; isLoadingDetail = false
                selectCommitFile(files.first?.id)
            } catch is CancellationError {
                if detailID == token { isLoadingDetail = false }
            } catch {
                guard detailID == token else { return }
                diffError = error.localizedDescription; isLoadingDetail = false
            }
        }
    }

    func selectCommitFile(_ id: String?) {
        selectedCommitFileID = id
        detailTask?.cancel(); detailID = UUID()
        diff = .empty; diffError = nil; isLoadingDetail = false
        guard let repository, let commit = selectedCommit,
              let file = commitFiles.first(where: { $0.id == id }) else { return }
        let token = detailID
        isLoadingDetail = true
        detailTask = Task {
            do {
                let text = try await repository.diff(file, in: commit)
                let document = await Task.detached { DiffDocument(text: text) }.value
                try Task.checkCancellation()
                guard detailID == token else { return }
                diff = document; isLoadingDetail = false
            } catch is CancellationError {
                if detailID == token { isLoadingDetail = false }
            } catch {
                guard detailID == token else { return }
                diffError = error.localizedDescription; isLoadingDetail = false
            }
        }
    }

    func stage(_ change: FileChange) { mutate("Staging change…") { try await $0.stage(change) } }
    func unstage(_ change: FileChange) { mutate("Unstaging change…") { try await $0.unstage(change) } }
    func stage(_ changes: [FileChange]) { mutate("Staging selected files…") { try await $0.stage(changes) } }
    func unstage(_ changes: [FileChange]) { mutate("Unstaging selected files…") { try await $0.unstage(changes) } }

    func canCheckout(_ reference: GitReference) -> Bool {
        canWrite && snapshot?.head != nil && !reference.isCurrent && reference.kind != .tag
            && reference.symbolicTarget == nil && (reference.kind == .localBranch
                || tools?.remotes.contains(where: { $0.ownsTrackingReference(reference) }) == true)
    }

    func requestBranch(_ destination: GitReference? = nil, startingAt oid: String? = nil) {
        guard canWrite, let snapshot, let head = snapshot.head else { return }
        if let destination, !canCheckout(destination) { return }
        let suggested = destination.flatMap { ref in
            tools?.remotes.sorted { $0.name.count > $1.name.count }
                .compactMap { $0.suggestedLocalName(for: ref) }.first
        } ?? ""
        sheet = .branch(BranchRequest(expected: snapshot, startingOID: oid ?? head,
                                      destination: destination, suggestedName: suggested))
    }

    func performBranch(_ request: BranchRequest, name: String) {
        guard repository?.root == request.expected.root, let head = request.expected.head else {
            show(GitError.staleRepository, title: "Repository changed"); return
        }
        sheet = nil
        if let destination = request.destination {
            mutate("Switching to " + destination.name + "…") {
                if destination.kind == .remoteBranch {
                    try await $0.checkoutRemote(destination, as: name, expected: request.expected)
                } else { try await $0.checkout(destination, expectedHead: head) }
            }
        } else {
            mutate("Creating branch…") { try await $0.createBranch(name: name, expectedHead: head, startingAt: request.startingOID) }
        }
    }

    func commit() {
        guard canCommit, let snapshot else { return }
        let message = commitMessage, fingerprint = snapshot.indexFingerprint
        mutate("Committing staged changes…", clearMessage: true) {
            try await $0.commit(message: message, expectedFingerprint: fingerprint)
        }
    }

    private func mutate(_ label: String, clearMessage: Bool = false,
                        operation: @escaping @Sendable (GitRepository) async throws -> Void) {
        guard canWrite, let repository else { return }
        runOperation(label, clearMessage: clearMessage) { try await operation(repository) }
    }

    /// Cancellation targets only the operation child. This owner remains uncancelled through
    /// reconciliation, so a cancelled write cannot skip the fresh snapshot or unlock early.
    private func runOperation(_ title: String, clearMessage: Bool = false, openAfter: URL? = nil,
                              operation: @escaping @Sendable () async throws -> Void) {
        guard !isBusy else { return }
        let originalRepository = repository
        cancelReads()
        isRefreshing = false; isLoadingDetail = false; isLoadingHistory = false
        operationPhase = .running; cancellationRequested = false; snapshotIsCurrent = false
        activity = title
        let record = OperationRecord(title: title, repositoryRoot: openAfter ?? originalRepository?.root, started: Date())
        operations.insert(record, at: 0)
        operations = Array(operations.prefix(30))
        let lifecycle = WriteLifecycle()
        runningLifecycle = lifecycle
        mutationTask = Task {
            var failures: [String] = []
            var completed = false, cancelled = false
            do {
                let result = try await lifecycle.execute(operation: operation, reconcile: {
                    try await originalRepository?.snapshot()
                }, willReconcile: {
                    await MainActor.run { self.operationPhase = .reconciling; self.activity = "Checking repository state…" }
                })
                do {
                    try result.operation.get()
                    completed = true
                    if clearMessage { commitMessage = "" }
                } catch is CancellationError {
                    cancelled = true
                    failures.append("Cancellation completed. Git may already have changed state; this is not an undo.")
                } catch { failures.append(error.localizedDescription) }
                do {
                    if let state = try result.reconciliation.get() { snapshot = state; snapshotIsCurrent = true }
                } catch { failures.append("Repository refresh also failed: " + error.localizedDescription) }
            } catch { failures.append(error.localizedDescription) }
            runningLifecycle = nil
            if let index = operations.firstIndex(where: { $0.id == record.id }) {
                operations[index].finished = Date()
                operations[index].outcome = failures.isEmpty ? .succeeded : (cancelled && (originalRepository == nil || snapshotIsCurrent) ? .cancelled : .failed)
                let success = openAfter == nil ? "Completed. Repository state checked." : "Creation completed. Opening the destination; the previous workspace was reconciled if present."
                let detail = failures.isEmpty ? success : failures.joined(separator: "\n\n")
                operations[index].detail = String(detail.prefix(12_000)) + (detail.count > 12_000 ? "\n[Activity preview truncated]" : "")
            }
            operationPhase = .idle
            activity = failures.isEmpty ? "Ready" : (cancelled ? "Cancelled · review state" : "Operation finished with an error")
            if !failures.isEmpty {
                notice = AppNotice(title: cancelled ? "Operation cancelled — review state" : "Git operation failed — review repository state",
                                   message: failures.joined(separator: "\n\n"))
            }
            mutationTask = nil
            if completed, let openAfter { open(openAfter) }
            else { reloadSelection() }
        }
    }

    func cancelOperation() {
        guard canCancelOperation else { return }
        guard let lifecycle = runningLifecycle else { return }
        cancellationRequested = true
        Task {
            let accepted = await lifecycle.cancel()
            guard runningLifecycle === lifecycle else { return }
            if !accepted { cancellationRequested = false }
            else if operationPhase == .running { activity = "Cancellation requested · waiting for Git and cleanup…" }
        }
    }

    private func reloadSelection() {
        switch section {
        case .changes: selectDefaultChange()
        case .stashes: selectStash(selectedStashID)
        case .history, .reference: loadHistory()
        }
    }

    var tools: CollaborationSnapshot? { snapshot?.collaboration.value }
    var canUseTools: Bool { canWrite && tools != nil }
    var selectedStash: GitStash? { tools?.stashes.first { $0.id == selectedStashID } }
    var canCancelOperation: Bool { operationPhase == .running && !cancellationRequested }

    func requestRemote(_ action: RemoteAction, name: String? = nil) {
        guard canUseTools, let snapshot else { return }
        sheet = .remote(RemoteRequest(action: action, expected: snapshot, initialRemote: name))
    }

    func performRemote(_ request: RemoteRequest, remote: GitRemote?, destination: String,
                       setUpstream: Bool, name: String, url: String) {
        guard repository?.root == request.expected.root else { show(GitError.staleRepository, title: "Repository changed"); return }
        sheet = nil
        let action = request.action
        mutate(action == .add ? "Adding remote…" : action.rawValue.capitalized + " · " + (remote?.name ?? "")) { repo in
            if action == .add { try await repo.addRemote(name: name, url: url, expected: request.expected); return }
            guard let remote else { throw GitError.invalidInput("Choose a remote first.") }
            switch action {
            case .fetch: try await repo.fetch(remote, expected: request.expected)
            case .pull: try await repo.pullFastForward(remote, expected: request.expected)
            case .push: try await repo.push(remote, branch: destination, setUpstream: setUpstream, expected: request.expected)
            case .add: break
            }
        }
    }

    func requestCreation(_ kind: CreationKind) { if !isBusy { sheet = .creation(kind) } }

    func performCreation(_ creation: RepositoryCreation, at destination: URL) {
        sheet = nil
        runOperation("Creating repository · " + destination.lastPathComponent, openAfter: destination) {
            _ = try await GitRepository.create(creation, at: destination)
        }
    }

    func requestStash(_ action: StashAction) {
        guard canUseTools, let snapshot else { return }
        sheet = .stash(StashRequest(action: action, expected: snapshot))
    }

    func performStash(_ request: StashRequest, message: String, includeUntracked: Bool, restoreIndex: Bool) {
        guard repository?.root == request.expected.root else { show(GitError.staleRepository, title: "Repository changed"); return }
        sheet = nil
        let title: String
        switch request.action {
        case .save: title = "Saving stash…"
        case .apply: title = "Applying stash · keeping recovery entry…"
        case .drop: title = "Dropping reviewed stash…"
        }
        mutate(title) { repo in
            switch request.action {
            case .save: try await repo.saveStash(message: message, includeUntracked: includeUntracked, expected: request.expected)
            case .apply(let stash): try await repo.applyStash(stash, restoreIndex: restoreIndex, expected: request.expected)
            case .drop(let stash): try await repo.dropStash(stash, expected: request.expected)
            }
        }
    }

    func selectStash(_ id: String?) {
        selectedStashID = tools?.stashes.contains(where: { $0.id == id }) == true ? id : tools?.stashes.first?.id
        detailTask?.cancel(); detailID = UUID()
        diff = .empty; diffError = nil; isLoadingDetail = false
        guard section == .stashes, let repository, let stash = selectedStash else { return }
        let token = detailID
        isLoadingDetail = true
        detailTask = Task {
            do {
                let text = try await repository.stashDiff(stash)
                let document = await Task.detached { DiffDocument(text: text) }.value
                try Task.checkCancellation()
                guard detailID == token else { return }
                diff = document; isLoadingDetail = false
            } catch is CancellationError { if detailID == token { isLoadingDetail = false } }
            catch {
                guard detailID == token else { return }
                diffError = error.localizedDescription; isLoadingDetail = false
            }
        }
    }

    func cancelReads() {
        refreshTask?.cancel(); detailTask?.cancel(); historyTask?.cancel()
        refreshID = UUID(); detailID = UUID(); historyID = UUID()
    }

    private func show(_ error: any Error, title: String) {
        notice = AppNotice(title: title, message: error.localizedDescription)
    }

    private func remember(_ url: URL) {
        guard !testing else { return }
        recentPaths = Array(([url.path] + recentPaths.filter { $0 != url.path }).prefix(8))
        UserDefaults.standard.set(recentPaths, forKey: "recentRepositories")
    }
}
