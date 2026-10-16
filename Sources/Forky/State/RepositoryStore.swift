import AppKit
import Foundation
import Observation
import ForkyCore

enum NavigationSection: Hashable {
    case changes, history, branch(String)
    var ref: String? { if case .branch(let value) = self { value } else { nil } }
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
    private(set) var diff = DiffDocument.empty
    private(set) var diffError: String?
    private(set) var historyError: String?
    private(set) var isLoading = false
    private(set) var isRefreshing = false
    private(set) var isLoadingDetail = false
    private(set) var isLoadingHistory = false
    private(set) var isMutating = false
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
    @ObservationIgnored private var bootstrapped = false
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
    var selectedFileName: String? {
        if section == .changes { selectedChange?.path }
        else { commitFiles.first { $0.id == selectedCommitFileID }?.path.value }
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
                self.repository = repository
                self.snapshot = snapshot
                snapshotIsCurrent = true
                section = .changes
                commits = []; commitFiles = []; selectedCommitID = nil; selectedCommitFileID = nil
                selectedChange = nil; diff = .empty; diffError = nil; historyError = nil
                commitMessage = ""
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
                if section == .changes { selectDefaultChange() }
                else { loadHistory() }
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
        if value == .changes { selectDefaultChange() }
        else { loadHistory() }
    }

    func selectChange(_ value: ChangeSelection?) {
        selectedChange = value
        loadChangeDiff()
    }

    private func selectDefaultChange() {
        if let selectedChange,
           let file = snapshot?.changes.first(where: { $0.id == selectedChange.path }),
           selectedChange.side == .staged ? file.isStaged : file.isUnstaged {
            loadChangeDiff()
        } else if let file = snapshot?.unstaged.first {
            selectChange(.init(path: file.id, side: .worktree))
        } else if let file = snapshot?.staged.first {
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

    func loadHistory(append: Bool = false) {
        guard let repository, !isMutating else { return }
        historyTask?.cancel(); historyID = UUID()
        let id = historyID, session = sessionID
        let offset = append ? commits.count : 0
        let ref = section.ref
        isLoadingHistory = true; historyError = nil
        historyTask = Task {
            do {
                let page = try await repository.history(ref: ref, offset: offset)
                try Task.checkCancellation()
                guard historyID == id, sessionID == session else { return }
                // External ref changes can reorder offset pages; suppress duplicate identities.
                let existing = append ? Set(commits.map(\.id)) : []
                commits = (append ? commits : []) + page.commits.filter { !existing.contains($0.id) }
                hasMoreHistory = page.hasMore; isLoadingHistory = false
                if !append {
                    let selected = commits.first { $0.id == selectedCommitID } ?? commits.first
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
        guard section != .changes else { return }
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
        cancelReads()
        isRefreshing = false; isLoadingDetail = false; isLoadingHistory = false
        isMutating = true; snapshotIsCurrent = false; activity = label
        mutationTask = Task {
            var failure: (any Error)?
            do {
                try await operation(repository)
                if clearMessage { commitMessage = "" }
            } catch { failure = error }
            // A failure is not a rollback. Always reconcile the actual repository.
            do { snapshot = try await repository.snapshot(); snapshotIsCurrent = true }
            catch {
                snapshotIsCurrent = false
                if failure == nil { failure = error }
            }
            isMutating = false
            activity = failure == nil ? "Ready" : "Operation finished with an error"
            if let failure { show(failure, title: "Git operation failed — review repository state") }
            if section == .changes { selectDefaultChange() } else { loadHistory() }
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
