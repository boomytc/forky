import SwiftUI
import ForkyCore

struct WorkspaceTabs: View {
    @Bindable var hub: WorkspaceHub
    @State private var renameTarget: SavedWorkspace?
    @State private var renameText = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                ScrollView(.horizontal) {
                    HStack(spacing: 3) {
                        ForEach(hub.tabs) { tab in
                            HStack(spacing: 7) {
                                Button { hub.selectedID = tab.id } label: {
                                    HStack(spacing: 6) {
                                        if tab.store.isMutating { ProgressView().controlSize(.mini) }
                                        Text(tab.title).lineLimit(1)
                                    }.padding(.vertical, 7).padding(.leading, 9)
                                }.buttonStyle(.plain)
                                Button { hub.close(tab) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                                    .buttonStyle(.plain).disabled(tab.store.isMutating).accessibilityLabel("Close " + tab.title)
                            }
                            .padding(.trailing, 9).background(tab.id == hub.selectedID ? Color.primary.opacity(0.08) : .clear, in: .rect(cornerRadius: 5))
                            .contextMenu {
                                Button("Close") { hub.close(tab) }.disabled(tab.store.isMutating)
                                Button("Open Another Tab for This Repository") { hub.newTab(tab.store.repository?.root) }
                            }
                        }
                    }
                }.scrollIndicators(.hidden)
                Button { hub.newTab() } label: { Image(systemName: "plus") }.buttonStyle(.plain).help("New Repository Tab")
                    .accessibilityIdentifier("newRepositoryTab")
                Menu {
                    Button("Reopen Closed Tab") { hub.reopen() }.disabled(hub.closed.isEmpty)
                    Divider()
                    ForEach(hub.selected.store.recentPaths, id: \.self) { path in
                        Button(URL(fileURLWithPath: path).lastPathComponent) { hub.newTab(URL(fileURLWithPath: path)) }
                    }
                    Divider()
                    Button("Save Open Repositories as Workspace") { hub.saveWorkspace(name: "Workspace " + String(hub.workspaces.count + 1)) }
                        .accessibilityIdentifier("workspaceSaveCurrent")
                    ForEach(hub.workspaces) { workspace in
                        Menu(workspace.name) {
                            Button("Open in New Tabs") { hub.openWorkspace(workspace) }
                            Button("Replace with Open Tabs") { hub.replaceWorkspacePaths(workspace.id) }
                            Button("Rename…") { renameTarget = workspace; renameText = workspace.name }
                                .accessibilityIdentifier("workspaceRename")
                            Button("Move Up") { hub.moveWorkspace(workspace.id, up: true) }
                            Button("Move Down") { hub.moveWorkspace(workspace.id, up: false) }
                            Divider()
                            Button("Delete Saved Workspace", role: .destructive) { hub.deleteWorkspace(workspace.id) }
                        }
                    }
                } label: { Image(systemName: "square.stack.3d.up") }.menuStyle(.borderlessButton).fixedSize()
                    .accessibilityIdentifier("workspaceMenu")
                    .alert("Rename Workspace", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
                        TextField("Name", text: $renameText).accessibilityIdentifier("workspaceRenameField")
                        Button("Rename") {
                            if let target = renameTarget { hub.renameWorkspace(target.id, to: renameText) }
                            renameTarget = nil
                        }.accessibilityIdentifier("workspaceRenameConfirm")
                        Button("Cancel", role: .cancel) { renameTarget = nil }
                    } message: { Text("Trimmed, at most 80 characters, no control characters.") }
            }.font(.system(size: 11)).padding(.horizontal, 10).padding(.vertical, 5)
            Divider()
            WorkspaceView(store: hub.selected.store).id(hub.selected.id)
        }
        .alert("Workspace", isPresented: Binding(get: { hub.notice != nil }, set: { if !$0 { hub.notice = nil } })) {
            Button("OK") { hub.notice = nil }
        } message: { Text(hub.notice ?? "") }
        .task { hub.restoreTabsIfNeeded() }
    }
}
