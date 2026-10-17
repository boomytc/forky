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
    var historyOptions = HistoryOptions()
    @ObservationIgnored private var pendingCommitPath: GitPath?
    private(set) var historyBack: [HistoryLocation] = []
    var canNavigateBack: Bool { !historyBack.isEmpty && !isMutating }
    var referenceQuery = ""
    var fileQuery = ""
    var diffMode = DiffMode.unified
    var diffOptions = DiffOptions()
    var selectedParentOID: String?
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
    var commitSignOff = false
    private(set) var commitTemplateText: String?
    private(set) var commitTemplateLabel: String?
    private(set) var commitCompositionNote: String?
    @ObservationIgnored private var commitCompositionLoaded = false
    private static let signOffDefaultPrefix = "forky.commitSignOff."
    var notice: AppNotice?
    var lastToolOutput: String?
    var lastToolBody: String?
    var latestDiagnostic: String?
    var gitExecutablePath = "/usr/bin/git"
    var explicitHelperPATH = ""

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
    @ObservationIgnored private var diskGeneration = 0
    @ObservationIgnored private var monitor: RepositoryMonitor?
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    var monitorWarning: String?
    var editDrafts: [String: String] = [:]
    @ObservationIgnored private let testing = ProcessInfo.processInfo.arguments.contains("--ui-testing")

    init() {
        if !testing {
            recentPaths = UserDefaults.standard.stringArray(forKey: "recentRepositories") ?? []
            gitExecutablePath = UserDefaults.standard.string(forKey: "forky.gitExecutable") ?? "/usr/bin/git"
            explicitHelperPATH = UserDefaults.standard.string(forKey: "forky.helperPATH") ?? ""
        }
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

    func useGitExecutable(_ path: String, helperPATH: String = "") {
        guard canWrite, path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
            show(GitError.invalidInput("Choose an existing absolute executable; nothing is installed."), title: "Invalid Git executable"); return
        }
        guard !helperPATH.utf8.contains(0), helperPATH.utf8.count <= 65536,
              helperPATH.isEmpty || helperPATH.split(separator: ":", omittingEmptySubsequences: false).allSatisfy({ $0.hasPrefix("/") }) else {
            show(GitError.invalidInput("Helper PATH must use absolute, nonempty directory entries; blank inherits without persisting ambient values."), title: "Invalid helper PATH"); return
        }
        gitExecutablePath = path; explicitHelperPATH = helperPATH
        if !testing {
            UserDefaults.standard.set(path, forKey: "forky.gitExecutable")
            if helperPATH.isEmpty { UserDefaults.standard.removeObject(forKey: "forky.helperPATH") }
            else { UserDefaults.standard.set(helperPATH, forKey: "forky.helperPATH") }
        }
        sheet = nil
        if let root = repository?.root { open(root) }
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
                var environment = ProcessInfo.processInfo.environment
                if !explicitHelperPATH.isEmpty { environment["PATH"] = explicitHelperPATH }
                let repository = try await GitRepository.open(url, runner: .init(executable: URL(fileURLWithPath: gitExecutablePath), environment: environment))
                try Task.checkCancellation()
                guard sessionID == session else { return }
                startMonitor(repository)
                let observedGeneration = diskGeneration
                let snapshot = try await repository.snapshot()
                try Task.checkCancellation()
                guard sessionID == session else { return }
                if let previous = self.repository { drafts[previous.root.path] = commitMessage }
                self.repository = repository
                self.snapshot = snapshot
                snapshotIsCurrent = observedGeneration == diskGeneration
                section = .changes; historyBack = []
                commits = []; commitFiles = []; selectedCommitID = nil; selectedCommitFileID = nil
                selectedChange = nil; diff = .empty; diffError = nil; historyError = nil
                commitMessage = drafts[repository.root.path] ?? ""
                commitCompositionLoaded = false
                commitTemplateText = nil; commitTemplateLabel = nil; commitCompositionNote = nil
                commitSignOff = storedSignOffDefault(repository.root.path)
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
                if let repository = self.repository { startMonitor(repository); invalidateFromDisk() }
                show(error, title: "Could not open repository")
            }
        }
    }

    private func startMonitor(_ repository: GitRepository) {
        monitorTask?.cancel(); monitor?.stop(); monitor = nil; monitorWarning = nil
        let session = sessionID
        do {
            monitor = try RepositoryMonitor(paths: [repository.root, repository.gitDirectory, repository.commonDirectory]) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.sessionID == session else { return }
                    self.invalidateFromDisk()
                }
            }
        } catch { monitorWarning = error.localizedDescription }
    }

    func invalidateFromDisk() {
        // The generation is changed synchronously. Late callbacks cannot target another root.
        snapshotIsCurrent = false; diskGeneration &+= 1
        monitorTask?.cancel()
        let session = sessionID
        monitorTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(550))
                while let self, self.isBusy {
                    try await Task.sleep(for: .milliseconds(150))
                }
                try Task.checkCancellation()
                guard let self, self.sessionID == session else { return }
                self.refresh()
            } catch {}
        }
    }

    func stopObserving() { monitor?.stop(); monitor = nil; monitorTask?.cancel() }
    func suspendSession() {
        guard !isMutating else { return }
        stopObserving(); cancelReads(); openTask?.cancel(); refreshTask?.cancel()
        sessionID = UUID()
        isLoading = false; isRefreshing = false; isLoadingDetail = false; isLoadingHistory = false
    }
    func resumeSession() {
        if let repository { startMonitor(repository); refresh() }
    }

    func refresh() {
        guard let repository, !isMutating, !isLoading else { return }
        refreshTask?.cancel()
        let id = UUID(); refreshID = id
        let session = sessionID, observedGeneration = diskGeneration
        isRefreshing = true
        activity = "Refreshing…"
        refreshTask = Task {
            do {
                let value = try await repository.snapshot()
                try Task.checkCancellation()
                guard sessionID == session, refreshID == id else { return }
                snapshot = value; snapshotIsCurrent = observedGeneration == diskGeneration
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
        let id = detailID, options = diffOptions
        isLoadingDetail = true
        detailTask = Task {
            do {
                let text = try await repository.diff(change, side: selection.side, options: options)
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
        let options = historyOptions
        if !append {
            commits = []; graph = .empty; decorations = [:]; hasMoreHistory = false; historyCursor = nil
            selectCommit(nil)
        }
        isLoadingHistory = true; historyError = nil
        historyTask = Task {
            do {
                if debounce { try await Task.sleep(for: .milliseconds(280)) }
                let page = try await repository.history(ref: ref, query: query, cursor: cursor, options: options)
                let values = previousCommits + page.commits
                let layout = await Task.detached { query.isEmpty && !options.firstParent ? CommitGraph(commits: values) : .empty }.value
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
        if !commit.parents.contains(selectedParentOID ?? "") { selectedParentOID = commit.parents.first }
        let token = detailID, parent = selectedParentOID
        isLoadingDetail = true
        detailTask = Task {
            do {
                let files = try await repository.files(in: commit, parent: parent)
                try Task.checkCancellation()
                guard detailID == token else { return }
                commitFiles = files; isLoadingDetail = false
                let selected = files.first { $0.path == pendingCommitPath } ?? files.first
                pendingCommitPath = nil
                selectCommitFile(selected?.id)
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
        let token = detailID, parent = selectedParentOID, options = diffOptions
        isLoadingDetail = true
        detailTask = Task {
            do {
                let text = try await repository.diff(file, in: commit, parent: parent, options: options)
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

    func diffSettingsChanged() {
        if section == .changes { loadChangeDiff() }
        else if section.isHistory { selectCommitFile(selectedCommitFileID) }
    }
    func parentChanged() { selectCommit(selectedCommitID) }

    func updateHistoryQuery(_ query: String) {
        guard query != historyQuery else { return }
        historyQuery = query; loadHistory(debounce: true)
    }
    func updateHistoryOptions(_ options: HistoryOptions) {
        guard options != historyOptions else { return }
        historyOptions = options; loadHistory()
    }
    private func rememberLocation() {
        let location = HistoryLocation(section: section, query: historyQuery, options: historyOptions,
            commits: commits, cursor: historyCursor, graph: graph, decorations: decorations,
            commitID: selectedCommitID, filePath: commitFiles.first { $0.id == selectedCommitFileID }?.path,
            parentOID: selectedParentOID, change: selectedChange, more: hasMoreHistory)
        historyBack.insert(location, at: 0)
        while historyBack.count > 8 || historyBack.reduce(0, { $0 + $1.commits.count }) > 10_000
                || historyBack.reduce(0, { $0 + $1.messageBytes }) > 16 * 1024 * 1024 { historyBack.removeLast() }
    }
    func navigateBack() {
        guard canNavigateBack else { return }
        let location = historyBack.removeFirst()
        cancelReads()
        section = location.section; historyQuery = location.query; historyOptions = location.options
        commits = location.commits; historyCursor = location.cursor; graph = location.graph; decorations = location.decorations
        hasMoreHistory = location.more; selectedChange = location.change
        if section.isHistory { pendingCommitPath = location.filePath; selectedParentOID = location.parentOID; selectCommit(location.commitID) }
        else { reloadSelection() }
    }

    func revealCommit(_ oid: String, path: GitPath? = nil) {
        guard let repository, !isMutating else { return }
        sheet = nil; detailTask?.cancel(); detailID = UUID()
        let token = detailID, session = sessionID
        detailTask = Task {
            do {
                let commit = try await repository.commitInfo(oid)
                try Task.checkCancellation()
                guard detailID == token, sessionID == session else { return }
                rememberLocation()
                historyTask?.cancel(); historyID = UUID(); isLoadingHistory = false
                section = .history; historyQuery = ""; historyOptions = .init()
                commits = [commit]; graph = .empty; decorations = [:]; historyCursor = nil; hasMoreHistory = false
                pendingCommitPath = path
                selectCommit(commit.id)
            } catch is CancellationError {} catch { show(error, title: "Commit unavailable") }
        }
    }

    func stage(_ change: FileChange) {
        if change.isConflict { requestAdvanced(.conflict(change)); return }
        mutate("Staging change…") { try await $0.stage(change) }
    }
    func unstage(_ change: FileChange) { mutate("Unstaging change…") { try await $0.unstage(change) } }
    func stage(_ changes: [FileChange]) {
        guard !changes.contains(where: \.isConflict) else {
            show(GitError.invalidInput("Resolve conflicts individually before batch staging."), title: "Conflicts require review"); return
        }
        mutate("Staging selected files…") { try await $0.stage(changes) }
    }
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

    /// Loads `commit.template` once per opened repository.
    /// A non-empty draft always wins over the template.
    func prepareCommitComposition() async {
        guard !commitCompositionLoaded, let repository else { return }
        commitCompositionLoaded = true
        do {
            let composition = try await repository.commitComposition()
            // The repository can change while configuration is read; never prefill another repository.
            guard self.repository?.root == repository.root else { return }
            commitTemplateText = composition.templateText
            commitTemplateLabel = composition.templatePath.map { ($0 as NSString).abbreviatingWithTildeInPath }
            commitCompositionNote = composition.note
            if commitMessage.isEmpty, let text = composition.templateText { commitMessage = text }
        } catch {
            commitCompositionNote = "Commit template is unavailable: " + error.localizedDescription
        }
    }

    /// The sign-off choice is Forky's own repository-scoped default; Git has no commit
    /// sign-off configuration key (`format.signoff` only affects `format-patch`).
    func updateCommitSignOff(_ value: Bool) {
        commitSignOff = value
        guard !testing, let path = repository?.root.path else { return }
        UserDefaults.standard.set(value, forKey: Self.signOffDefaultPrefix + path)
    }
    private func storedSignOffDefault(_ path: String) -> Bool {
        guard !testing else { return false }
        return UserDefaults.standard.bool(forKey: Self.signOffDefaultPrefix + path)
    }

    func commit() {
        guard canCommit, let snapshot else { return }
        let message = commitMessage, fingerprint = snapshot.indexFingerprint
        // The checkbox is authoritative for this commit; the stored choice only seeds its initial state.
        let signOff: CommitSignOff = commitSignOff ? .include : .omit
        mutate("Committing staged changes…", clearMessage: true) {
            try await $0.commit(message: message, signOff: signOff, expectedFingerprint: fingerprint)
        }
    }

    func mutate(_ label: String, clearMessage: Bool = false,
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
                    let generation = await MainActor.run { self.diskGeneration }
                    return (try await originalRepository?.snapshot(), generation)
                }, willReconcile: {
                    await MainActor.run { self.operationPhase = .reconciling; self.activity = "Checking repository state…" }
                })
                do {
                    try result.operation.get()
                    completed = true
                    if clearMessage { commitMessage = commitTemplateText ?? "" }
                } catch is CancellationError {
                    cancelled = true
                    failures.append("Cancellation completed. Git may already have changed state; this is not an undo.")
                } catch { failures.append(error.localizedDescription) }
                do {
                    let observed = try result.reconciliation.get()
                    if let state = observed.0 { snapshot = state; snapshotIsCurrent = observed.1 == diskGeneration }
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
                latestDiagnostic = title + "\n" + (originalRepository?.root.path ?? "") + "\n\n" + failures.joined(separator: "\n\n")
                notice = AppNotice(title: cancelled ? "Operation cancelled — review state" : "Git operation failed — review repository state",
                                   message: String(failures.joined(separator: "\n\n").prefix(12_000)) + (failures.joined(separator: "\n\n").count > 12_000 ? "\n[Alert preview truncated; full latest diagnostics are in Activity.]" : ""))
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

    func show(_ error: any Error, title: String) {
        notice = AppNotice(title: title, message: error.localizedDescription)
    }

    private func remember(_ url: URL) {
        guard !testing else { return }
        recentPaths = Array(([url.path] + recentPaths.filter { $0 != url.path }).prefix(8))
        UserDefaults.standard.set(recentPaths, forKey: "recentRepositories")
    }
}
