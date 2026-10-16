import SwiftUI

struct SyncControls: View {
    let store: RepositoryStore
    private var hasRemote: Bool { store.tools?.remotes.isEmpty == false }
    private var branchReady: Bool {
        store.canUseTools && store.snapshot?.branch != nil && store.snapshot?.head != nil
            && store.snapshot?.operationInProgress == false && store.snapshot?.hasConflicts == false
    }
    var body: some View {
        HStack(spacing: 12) {
            Button("Fetch", systemImage: "arrow.down.to.line") { store.requestRemote(.fetch) }
                .disabled(!store.canUseTools || !hasRemote).help("Fetch remote tracking refs without changing working files")
                .accessibilityIdentifier("fetchRemote")
            Button {
                store.requestRemote(.pull)
            } label: {
                Label("Pull" + count(store.tools?.tracking?.behind), systemImage: "arrow.down")
            }
            .disabled(!branchReady || store.tools?.tracking == nil || !hasRemote)
            .help("Fetch and fast-forward only. Commit or stash local changes first.")
            .accessibilityIdentifier("pullRemote")
            Button {
                store.requestRemote(.push)
            } label: {
                Label(store.tools?.tracking == nil ? "Publish" : "Push" + count(store.tools?.tracking?.ahead),
                      systemImage: "arrow.up")
            }
            .disabled(!branchReady || !hasRemote).help("Review the remote and branch before pushing. Never force.")
            .accessibilityIdentifier("pushRemote")
        }.font(.system(size: 12)).labelStyle(.titleAndIcon)
    }
    private func count(_ count: Int?) -> String { if let count, count > 0 { " " + String(count) } else { "" } }
}

struct TrackingStatus: View {
    let store: RepositoryStore
    var body: some View {
        if let tools = store.tools {
            if let tracking = tools.tracking {
                Text((tracking.ahead.map { "↑" + String($0) } ?? "↑?")
                     + " " + (tracking.behind.map { "↓" + String($0) } ?? "↓?") + "  " + tracking.label)
                    .monospacedDigit().lineLimit(1)
                    .help("Based on locally known refs, not a live server query. Fetch to update. Unknown counts mean the upstream is unavailable locally.")
                    .accessibilityIdentifier("trackingStatus")
            } else if tools.remotes.isEmpty {
                Button("Local only · Add Remote…") { store.requestRemote(.add) }
                    .buttonStyle(.plain).disabled(!store.canUseTools).accessibilityIdentifier("addRemote")
            } else {
                Text(store.snapshot?.branch == nil ? "Detached HEAD" : "No upstream · Publish to track")
                    .help("Publishing can configure an upstream; no network operation runs automatically.")
            }
        } else {
            Text("Sync state unavailable").foregroundStyle(.orange).help(store.snapshot?.collaboration.error ?? "")
        }
    }
}
