import AppKit
import SwiftUI

@main
struct ForkyApp: App {
    @State private var hub = WorkspaceHub()
    private var store: RepositoryStore { hub.selected.store }
    @NSApplicationDelegateAdaptor(ForkyAppDelegate.self) private var delegate

    var body: some Scene {
        Window("Forky", id: "main") {
            WorkspaceTabs(hub: hub)
                .frame(minWidth: 980, minHeight: 640)
                .tint(ForkyTheme.accent)
                .task {
                    delegate.hub = hub
                    store.bootstrap()
                }
        }
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Repository Tab") { hub.newTab() }.keyboardShortcut("t")
                Button("Reopen Closed Tab") { hub.reopen() }.keyboardShortcut("t", modifiers: [.command, .shift]).disabled(hub.closed.isEmpty)
                Button("Open Repository…", action: store.chooseRepository)
                    .keyboardShortcut("o")
                    .disabled(store.isMutating)
                Button("Clone Repository…") { store.requestCreation(.clone) }.disabled(store.isBusy)
                Button("Create Repository…") { store.requestCreation(.initialize) }.disabled(store.isBusy)
            }
            CommandGroup(after: .newItem) {
                Button("Refresh Repository", action: store.refresh)
                    .keyboardShortcut("r")
                    .disabled(store.repository == nil || store.isBusy)
            }
            CommandMenu("Tools") {
                ForEach(QueryTool.allCases) { tool in Button(tool.rawValue) { store.requestQuery(tool) }.disabled(store.repository == nil || store.isMutating) }
                Divider()
                ForEach(ManagementTool.allCases) { tool in Button(tool.rawValue) { store.requestManagement(tool) }.disabled(!store.canWrite) }
            }
            CommandMenu("Repository") {
                Button("Working Changes") { store.navigate(.changes) }.keyboardShortcut("1")
                Button("All Commits") { store.navigate(.history) }.keyboardShortcut("2")
                Button("Stashes") { store.navigate(.stashes) }.keyboardShortcut("3")
                Divider()
                Button("Fetch…") { store.requestRemote(.fetch) }.disabled(!store.canUseTools)
                Button("Pull · Fast-forward Only…") { store.requestRemote(.pull) }.disabled(!store.canUseTools)
                Button("Push / Publish…") { store.requestRemote(.push) }.disabled(!store.canUseTools)
                Button("Add Remote…") { store.requestRemote(.add) }.disabled(!store.canUseTools)
                Button("Stash Changes…") { store.requestStash(.save) }
                    .keyboardShortcut("s", modifiers: [.command, .shift]).disabled(!store.canUseTools)
                Button("Repository Activity…") { store.sheet = .activity }
                Divider()
                Button("New Branch…") { store.requestBranch() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(!store.canWrite || store.snapshot?.head == nil)
                Divider()
                Button("Commit Staged Changes", action: store.commit)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!store.canCommit)
                Divider()
                Button("Reveal in Finder") {
                    if let root = store.repository?.root { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: root.path) }
                }.disabled(store.repository == nil)
            }
        }
    }
}

@MainActor
final class ForkyAppDelegate: NSObject, NSApplicationDelegate {
    weak var hub: WorkspaceHub?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard hub?.isWriting == true else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "A Git write is still running"
        alert.informativeText = "Wait for the operation and repository refresh to finish before quitting."
        alert.addButton(withTitle: "Keep Forky Open")
        alert.runModal()
        return .terminateCancel
    }
}
