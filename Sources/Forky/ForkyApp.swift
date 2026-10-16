import AppKit
import SwiftUI

@main
struct ForkyApp: App {
    @State private var store = RepositoryStore()
    @NSApplicationDelegateAdaptor(ForkyAppDelegate.self) private var delegate

    var body: some Scene {
        Window("Forky", id: "main") {
            WorkspaceView(store: store)
                .frame(minWidth: 980, minHeight: 640)
                .tint(ForkyTheme.accent)
                .task {
                    delegate.store = store
                    store.bootstrap()
                }
        }
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Repository…", action: store.chooseRepository)
                    .keyboardShortcut("o")
                    .disabled(store.isMutating)
            }
            CommandGroup(after: .newItem) {
                Button("Refresh Repository", action: store.refresh)
                    .keyboardShortcut("r")
                    .disabled(store.repository == nil || store.isBusy)
            }
            CommandMenu("Repository") {
                Button("Working Changes") { store.navigate(.changes) }.keyboardShortcut("1")
                Button("All Commits") { store.navigate(.history) }.keyboardShortcut("2")
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
    weak var store: RepositoryStore?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard store?.isMutating == true else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "A Git write is still running"
        alert.informativeText = "Wait for the operation and repository refresh to finish before quitting."
        alert.addButton(withTitle: "Keep Forky Open")
        alert.runModal()
        return .terminateCancel
    }
}
