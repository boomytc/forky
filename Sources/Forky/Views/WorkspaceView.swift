import SwiftUI
import ForkyCore

struct WorkspaceView: View {
    @Bindable var store: RepositoryStore
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if store.repository != nil {
                NavigationSplitView {
                    SidebarView(store: store)
                        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 300)
                } detail: {
                    VStack(spacing: 0) {
                        if !store.snapshotIsCurrent && !store.isBusy {
                            Label("Repository state is stale. Refresh before making changes.", systemImage: "exclamationmark.triangle")
                                .font(.callout).foregroundStyle(.orange).padding(10)
                        }
                        OperationStrip(store: store)
                        OperationBanner(store: store)
                        switch store.section {
                        case .changes: ChangesView(store: store)
                        case .stashes: StashView(store: store)
                        case .history, .reference: HistoryView(store: store)
                        }
                        StatusBar(store: store)
                    }.id(store.repository?.root)
                }
            } else {
                WelcomeView(store: store)
            }
        }
        .navigationTitle(store.repository?.root.lastPathComponent ?? "Forky")
        .navigationSubtitle(store.snapshot?.branchLabel ?? "A little clarity for your Git workflow.")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Menu {
                    Button("Open Repository…", action: store.chooseRepository)
                    Button("Clone Repository…") { store.requestCreation(.clone) }
                    Button("Create Repository…") { store.requestCreation(.initialize) }
                    Divider()
                    Button("Show in Finder") {
                        if let root = store.repository?.root { NSWorkspace.shared.activateFileViewerSelecting([root]) }
                    }.disabled(store.repository == nil)
                } label: { Label("Repositories", systemImage: "folder.badge.plus") }
                    .labelStyle(.iconOnly).help("Open, clone or create repository").disabled(store.isBusy)
                    .accessibilityIdentifier("repositoryMenu")
            }
            ToolbarItem(placement: .automatic) { SyncControls(store: store) }
            ToolbarItem(placement: .automatic) {
                Button("New Branch", systemImage: "arrow.triangle.branch") { store.requestBranch() }
                    .labelStyle(.iconOnly).help("Create branch at HEAD · ⇧⌘N")
                    .disabled(!store.canWrite || store.snapshot?.head == nil).accessibilityIdentifier("newBranch")
            }
            ToolbarItem(placement: .automatic) {
                Button("Stash Changes", systemImage: "archivebox") { store.requestStash(.save) }
                    .labelStyle(.iconOnly).help("Save unfinished changes · ⇧⌘S")
                    .disabled(!store.canUseTools || store.snapshot?.head == nil || store.snapshot?.changes.isEmpty != false)
                    .accessibilityIdentifier("stashChanges")
            }
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 12) {
                    if store.isLoading || store.isRefreshing { ProgressView().controlSize(.small) }
                    Button("Activity", systemImage: "clock") { store.sheet = .activity }
                        .labelStyle(.iconOnly).help("Recent Git operations").accessibilityIdentifier("showActivity")
                    Button("Refresh", systemImage: "arrow.clockwise", action: store.refresh)
                        .labelStyle(.iconOnly).help("Refresh repository · ⌘R")
                        .disabled(store.repository == nil || store.isBusy)
                        .accessibilityIdentifier("refreshRepository")
                }
            }
        }
        .sheet(item: $store.sheet) { sheet in
            switch sheet {
            case .branch(let request): BranchSheet(request: request, store: store)
            case .remote(let request): RemoteSheet(request: request, store: store)
            case .stash(let request): StashSheet(request: request, store: store)
            case .creation(let kind): CreationSheet(kind: kind, store: store)
            case .activity: ActivityView(store: store)
            case .advanced(let request): AdvancedSheet(request: request, store: store)
            }
        }
        .alert(store.notice?.title ?? "Git Error", isPresented: Binding(
            get: { store.notice != nil }, set: { if !$0 { store.notice = nil } }
        )) {
            Button("OK", role: .cancel) { store.notice = nil }
        } message: {
            Text(store.notice?.message ?? "")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && store.repository != nil && !store.isBusy { store.refresh() }
        }
    }
}

private struct WelcomeView: View {
    let store: RepositoryStore

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            ForkyMark(size: 76)
            Text("Meet your next commit.").font(.system(size: 32, weight: .semibold)).padding(.top, 24)
            Text("A focused, native workspace for your Git repositories.")
                .font(.title3).foregroundStyle(.secondary).padding(.top, 8)
            Button("Open a Repository…", action: store.chooseRepository)
                .buttonStyle(.borderedProminent).controlSize(.large)
                .padding(.top, 28).disabled(store.isLoading)
                .accessibilityIdentifier("welcomeOpenRepository")
            HStack(spacing: 12) {
                Button("Clone Repository…") { store.requestCreation(.clone) }.accessibilityIdentifier("welcomeClone")
                Button("Create Repository…") { store.requestCreation(.initialize) }.accessibilityIdentifier("welcomeCreate")
            }.padding(.top, 12).disabled(store.isBusy)
            OperationStrip(store: store).frame(maxWidth: 580).padding(.top, store.isMutating ? 18 : 0)
            Text("⌘O  ·  No automatic network operations")
                .font(.caption).foregroundStyle(.tertiary).padding(.top, 12)
            if store.isLoading { ProgressView("Opening repository…").padding(.top, 20) }
            if !store.recentPaths.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("RECENT REPOSITORIES").font(.caption).foregroundStyle(.secondary)
                    ForEach(store.recentPaths, id: \.self) { path in
                        Button {
                            store.open(URL(fileURLWithPath: path, isDirectory: true))
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "folder").foregroundStyle(ForkyTheme.accent)
                                Text(URL(fileURLWithPath: path).lastPathComponent)
                                Spacer()
                                Image(systemName: "arrow.up.left").foregroundStyle(.tertiary)
                            }.padding(10).contentShape(.rect)
                        }.buttonStyle(.plain)
                    }
                }
                .frame(width: 360).padding(16)
                .background(ForkyTheme.panel, in: .rect(cornerRadius: 12))
                .padding(.top, 32)
            }
            Spacer()
            Text("FORKY  /  BUILT FOR macOS").font(.system(size: 10, weight: .medium, design: .monospaced))
                .tracking(2).foregroundStyle(.tertiary).padding(.bottom, 24)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct StatusBar: View {
    let store: RepositoryStore
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(store.snapshotIsCurrent ? ForkyTheme.accent : .orange).frame(width: 6, height: 6)
            Text(store.activity)
            Divider().frame(height: 11)
            TrackingStatus(store: store)
            Spacer()
            if let snapshot = store.snapshot {
                Text("\(snapshot.changes.count) changed · \(snapshot.staged.count) staged")
            }
            if let root = store.repository?.root {
                Divider().frame(height: 11)
                Text(root.path).lineLimit(1).truncationMode(.middle).help(root.path)
            }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .padding(.horizontal, 12).frame(height: 24)
        .background(.bar).overlay(alignment: .top) { Divider() }
    }
}
