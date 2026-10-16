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
                        .navigationSplitViewColumnWidth(min: 195, ideal: 225, max: 310)
                } detail: {
                    VStack(spacing: 0) {
                        if !store.snapshotIsCurrent && !store.isBusy {
                            Label("Repository state is stale. Refresh before making changes.", systemImage: "exclamationmark.triangle")
                                .font(.callout).foregroundStyle(.orange).padding(10)
                        }
                        if store.section == .changes { ChangesView(store: store) }
                        else { HistoryView(store: store) }
                        StatusBar(store: store)
                    }
                }
            } else {
                WelcomeView(store: store)
            }
        }
        .navigationTitle(store.repository?.root.lastPathComponent ?? "Forky")
        .navigationSubtitle(store.snapshot?.branchLabel ?? "A little clarity for your Git workflow.")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Open Repository", systemImage: "folder.badge.plus", action: store.chooseRepository)
                    .labelStyle(.iconOnly).help("Open repository · ⌘O").disabled(store.isMutating)
                    .accessibilityIdentifier("openRepository")
            }
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 12) {
                    if store.isBusy { ProgressView().controlSize(.small) }
                    Button("Refresh", systemImage: "arrow.clockwise", action: store.refresh)
                        .labelStyle(.iconOnly).help("Refresh repository · ⌘R")
                        .disabled(store.repository == nil || store.isBusy)
                        .accessibilityIdentifier("refreshRepository")
                }
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
            Text("⌘O  ·  Your files stay on your Mac")
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
        .padding(.horizontal, 14).frame(height: 29)
        .background(.bar).overlay(alignment: .top) { Divider() }
    }
}
