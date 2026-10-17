import Foundation
import Observation
import ForkyCore

@MainActor @Observable
final class RepositoryTab: Identifiable {
    let id = UUID()
    let store = RepositoryStore()
    var title: String { store.repository?.root.lastPathComponent ?? "Start" }
}
struct SavedWorkspace: Identifiable, Codable {
    let id: UUID
    var name: String
    let paths: [String]
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
    init() {
        let first = RepositoryTab()
        tabs = [first]; selectedID = first.id
        if !testing, let data = UserDefaults.standard.data(forKey: "forky.workspaces") {
            do {
                guard data.count <= 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                workspaces = try JSONDecoder().decode([SavedWorkspace].self, from: data)
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
        if let url { tab.store.open(url) }
    }
    func close(_ tab: RepositoryTab) {
        guard !tab.store.isMutating else { notice = "Wait for Git and final reconciliation before closing this tab."; return }
        tab.store.suspendSession()
        tabs.removeAll { $0.id == tab.id }
        closed.insert(tab, at: 0); closed = Array(closed.prefix(8))
        if tabs.isEmpty { tabs = [RepositoryTab()] }
        if !tabs.contains(where: { $0.id == selectedID }) { selectedID = tabs[0].id }
    }
    func reopen() {
        guard tabs.count < 16, !closed.isEmpty else { return }
        let tab = closed.removeFirst(); tabs.append(tab); selectedID = tab.id; tab.store.resumeSession()
    }
    func saveWorkspace(name: String) {
        guard !persistenceBlocked else { notice = "Original workspace settings are malformed/unavailable; export or repair them before replacing saved data."; return }
        let paths = tabs.compactMap { $0.store.repository?.root.path }
        guard !paths.isEmpty, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        workspaces.append(SavedWorkspace(id: UUID(), name: name, paths: paths)); persist()
    }
    func deleteWorkspace(_ id: UUID) { workspaces.removeAll { $0.id == id }; persist() }
    func openWorkspace(_ workspace: SavedWorkspace) {
        do {
            let paths = try workspace.paths.map(LocalFilePath.absolute)
            for url in paths { newTab(url) }
        } catch { notice = error.localizedDescription }
    }
    private func persist() {
        guard !testing, !persistenceBlocked else { return }
        if let data = try? JSONEncoder().encode(workspaces) { UserDefaults.standard.set(data, forKey: "forky.workspaces") }
    }
}
