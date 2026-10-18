import SwiftUI
import ForkyCore

struct QuerySheet: View {
    let request: QueryRequest
    let store: RepositoryStore
    @State private var text = ""
    @State private var failure: String?
    @State private var busy = false
    @State private var path = ""
    @State private var from = ""
    @State private var to = ""
    @State private var worktree = false
    @State private var reflog: [ReflogEntry] = []
    @State private var revisions: [FileRevision] = []
    @State private var reflogCursor: ReflogCursor?
    @State private var fileCursor: FileHistoryCursor?
    @State private var loadingMore = false
    @State private var pageWentStale = false
    @State private var loadID = UUID()
    var body: some View {
        if request.tool == .statistics { StatisticsSheet(request: request, store: store) }
        else { AdvancedFrame(title: request.tool.rawValue, subtitle: request.expected.root.path) {
            VStack(spacing: 0) {
                if request.tool == .fileHistory {
                    HStack {
                        TextField("Repository-relative path", text: $path).textFieldStyle(.roundedBorder).accessibilityIdentifier("queryPath")
                        Button("Load History") { loadID = UUID() }.disabled(busy || path.isEmpty)
                    }.padding(12)
                }
                if request.tool == .compare {
                    VStack {
                        refPicker("From", value: $from); refPicker("To", value: $to)
                        HStack {
                            Button("Swap") { swap(&from, &to) }.disabled(worktree)
                            Toggle("Compare against live worktree (index + unstaged)", isOn: $worktree)
                            Button("Compare") { loadID = UUID() }.disabled(busy || from.isEmpty || (!worktree && to.isEmpty))
                        }
                    }.padding(12)
                }
                if busy { ProgressView("Reading bounded local evidence…").padding() }
                if let failure { FeatureError(text: failure) }
                if request.tool == .reflog {
                    List(reflog) { entry in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(entry.message).lineLimit(2)
                                Text(entry.selector + " · " + entry.oid).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Show Commit") { store.revealCommit(entry.oid) }
                                .help("Then use Create Branch Here to recover without reset.")
                        }
                    }
                } else if request.tool == .fileHistory {
                    List(revisions) { revision in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(revision.commit.subject)
                                Text(revision.path.value + " · " + revision.commit.shortOID).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Show Commit") { store.revealCommit(revision.commit.oid, path: revision.path) }
                        }
                    }
                } else { SourceTextView(text: text, identifier: "queryResult") }
                if request.tool == .reflog || request.tool == .fileHistory { pagingFooter }
            }
        } actions: {
            Button("Close") { store.sheet = nil }.keyboardShortcut(.cancelAction)
            Spacer()
            Text("Read-only · no checkout or network").font(.caption).foregroundStyle(.secondary)
        }
        .task {
            path = request.path?.value ?? ""
            from = request.oid ?? ""
            to = request.expected.head ?? ""
            loadID = UUID()
        }
        .task(id: loadID) { await load() }
        }
    }
    private func refPicker(_ title: String, value: Binding<String>) -> some View {
        HStack {
            TextField(title + " commit OID", text: value).textFieldStyle(.roundedBorder)
            Menu("Use Ref") {
                ForEach(request.expected.references.filter { $0.commitOID != nil }) { ref in
                    Button(ref.fullName) { value.wrappedValue = ref.commitOID ?? "" }
                }
            }.fixedSize()
        }
    }
    @ViewBuilder private var pagingFooter: some View {
        if pageWentStale {
            HStack(spacing: 8) {
                Text("HEAD moved after this page was read, so older positions no longer line up.")
                    .font(.caption).foregroundStyle(.orange)
                Spacer()
                Button("Reload From Newest") { pageWentStale = false; loadID = UUID() }
                    .accessibilityIdentifier("queryReloadNewest")
            }.padding(8)
        } else if reflogCursor != nil || fileCursor != nil {
            HStack(spacing: 8) {
                Text("Older records are loaded on request; the list is not proof of complete history.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if loadingMore { ProgressView().controlSize(.small) }
                Button("Load Older") { Task { await loadMore() } }
                    .disabled(loadingMore || busy)
                    .accessibilityIdentifier("queryLoadOlder")
            }.padding(8)
        }
    }
    private func load() async {
        busy = true; failure = nil; pageWentStale = false
        reflogCursor = nil; fileCursor = nil
        do {
            if request.tool == .overview {
                let value = try await request.repository.overview()
                try Task.checkCancellation(); text = value
            } else if request.tool == .reflog {
                let page = try await request.repository.reflog()
                try Task.checkCancellation(); reflog = page.entries; reflogCursor = page.nextCursor
            } else if request.tool == .fileHistory {
                guard let oid = request.oid, !path.isEmpty else { busy = false; return }
                let page = try await request.repository.fileHistory(at: oid, path: GitPath(path))
                try Task.checkCancellation(); revisions = page.entries; fileCursor = page.nextCursor
            } else if request.tool == .compare {
                guard !from.isEmpty, worktree || !to.isEmpty else { busy = false; return }
                let comparison = try await request.repository.compare(from: from, to: worktree ? nil : to)
                try Task.checkCancellation()
                text = comparison.from + " → " + (comparison.to ?? "live worktree") + "\n\(comparison.files.count) files\n\n" + comparison.patch
            }
            try Task.checkCancellation(); busy = false
        } catch is CancellationError {} catch { busy = false; failure = error.localizedDescription }
    }
    private func loadMore() async {
        guard !busy, !loadingMore else { return }
        loadingMore = true; failure = nil
        do {
            switch request.tool {
            case .reflog:
                guard let cursor = reflogCursor else { loadingMore = false; return }
                do {
                    let page = try await request.repository.reflog(after: cursor)
                    try Task.checkCancellation()
                    let known = Set(reflog.map(\.id))
                    reflog.append(contentsOf: page.entries.filter { !known.contains($0.id) })
                    reflogCursor = page.nextCursor
                } catch GitError.staleRepository {
                    pageWentStale = true
                }
            case .fileHistory:
                guard let cursor = fileCursor, let oid = request.oid, !path.isEmpty else { loadingMore = false; return }
                let page = try await request.repository.fileHistory(at: oid, path: GitPath(path), after: cursor)
                try Task.checkCancellation()
                let known = Set(revisions.map(\.id))
                revisions.append(contentsOf: page.entries.filter { !known.contains($0.id) })
                fileCursor = page.nextCursor
            default: break
            }
        } catch is CancellationError {} catch { failure = error.localizedDescription }
        loadingMore = false
    }
}
