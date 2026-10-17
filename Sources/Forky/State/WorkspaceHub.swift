import Foundation
import Observation
import ForkyCore

@MainActor @Observable
final class RepositoryTab: Identifiable {
    let id = UUID()
    let store = RepositoryStore()
    var title: String { store.repository?.root.lastPathComponent ?? "Start" }
}

@MainActor @Observable
final class WorkspaceHub {
    private(set) var tabs: [RepositoryTab]
    var selectedID: UUID
    private(set) var closed: [RepositoryTab] = []
    private(set) var workspaces: [SavedWorkspace] = []
    var notice: String?
    private var persistenceBlocked = false
    private let testing = ProcessInfo.processInfo.arguments.contains("--ui-testing")
    private var restoredTabs = false
    @ObservationIgnored private var tabPaths: [UUID: String] = [:]

    init() {
        let first = RepositoryTab()
        tabs = [first]; selectedID = first.id
        if !testing, let data = UserDefaults.standard.data(forKey: "forky.workspaces") {
            do {
                workspaces = try WorkspaceArchive.decode(data)
            } catch {
                persistenceBlocked = true
                notice = "Saved workspaces are unavailable: " + error.localizedDescription + ". Original settings are retained and will not be overwritten."
            }
        }
    }
    var selected: RepositoryTab { tabs.first { $0.id == selectedID } ?? tabs[0] }
    var isWriting: Bool { tabs.contains { $0.store.isMutating } }
    func newTab(_ url: URL? = nil) {
        // Bound retained view state and simultaneous filesystem subscriptions.
        guard tabs.count < 16 else { notice = "Close a repository tab first (16-session memory/subscription budget)."; return }
        let tab = RepositoryTab(); tabs.append(tab); selectedID = tab.id
        tab.store.onRepositoryOpened = { [weak self] root in
            guard let self else { return }
            self.tabPaths[tab.id] = root.path
            self.persistOpenTabs()
        }
        if let url {
            tabPaths[tab.id] = url.path
            tab.store.open(url)
        }
        persistOpenTabs()
    }
    func close(_ tab: RepositoryTab) {
        guard !tab.store.isMutating else { notice = "Wait for Git and final reconciliation before closing this tab."; return }
        tab.store.suspendSession()
        tabs.removeAll { $0.id == tab.id }
        tabPaths[tab.id] = nil
        closed.insert(tab, at: 0); closed = Array(closed.prefix(8))
        if tabs.isEmpty { tabs = [RepositoryTab()] }
        if !tabs.contains(where: { $0.id == selectedID }) { selectedID = tabs[0].id }
        persistOpenTabs()
    }
    func reopen() {
        guard tabs.count < 16, !closed.isEmpty else { return }
        let tab = closed.removeFirst(); tabs.append(tab); selectedID = tab.id; tab.store.resumeSession()
        if let path = tab.store.repository?.root.path { tabPaths[tab.id] = path }
        persistOpenTabs()
    }
    func saveWorkspace(name: String) {
        guard !persistenceBlocked else { notice = "Original workspace settings are malformed/unavailable; export or repair them before replacing saved data."; return }
        let paths = tabs.compactMap { $0.store.repository?.root.path }
        guard !paths.isEmpty else { return }
        do {
            workspaces = try WorkspaceArchive.appending(workspaces, name: name, paths: paths)
            persist()
        } catch { notice = error.localizedDescription }
    }
    func renameWorkspace(_ id: UUID, to name: String) {
        do { workspaces = try WorkspaceArchive.rename(workspaces, id: id, to: name); persist() }
        catch { notice = error.localizedDescription }
    }
    func moveWorkspace(_ id: UUID, up: Bool) {
        workspaces = WorkspaceArchive.move(workspaces, id: id, up: up)
        persist()
    }
    func replaceWorkspacePaths(_ id: UUID) {
        let paths = tabs.compactMap { $0.store.repository?.root.path }
        guard !paths.isEmpty else { notice = "Open at least one repository before replacing a saved workspace."; return }
        do { workspaces = try WorkspaceArchive.replacePaths(workspaces, id: id, paths: paths); persist() }
        catch { notice = error.localizedDescription }
    }
    func deleteWorkspace(_ id: UUID) {
        workspaces.removeAll { $0.id == id }
        persist()
    }
    func openWorkspace(_ workspace: SavedWorkspace) {
        do {
            let paths = try workspace.paths.map(LocalFilePath.absolute)
            for url in paths { newTab(url) }
        } catch { notice = error.localizedDescription }
    }

    /// Restores at most four repository tabs from the last session; missing paths are skipped quietly.
    func restoreTabsIfNeeded() {
        guard !testing, !restoredTabs else { return }
        restoredTabs = true
        let paths = UserDefaults.standard.stringArray(forKey: "forky.openTabs") ?? []
        var index = 0
        for path in paths where index < 4 && tabs.count < 16 {
            guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else { continue }
            newTab(URL(fileURLWithPath: path, isDirectory: true))
            index += 1
        }
    }

    private func persist() {
        guard !testing, !persistenceBlocked else { return }
        guard let data = try? WorkspaceArchive.encode(workspaces) else {
            notice = SessionArchiveError.tooLarge.localizedDescription
            return
        }
        UserDefaults.standard.set(data, forKey: "forky.workspaces")
    }
    private func persistOpenTabs() {
        guard !testing else { return }
        var seen = Set<String>(), paths: [String] = []
        for tab in tabs {
            guard let path = tabPaths[tab.id] ?? tab.store.repository?.root.path,
                  seen.insert(path).inserted else { continue }
            paths.append(path)
            guard paths.count <= 16 else { break }
        }
        UserDefaults.standard.set(paths, forKey: "forky.openTabs")
    }
}
