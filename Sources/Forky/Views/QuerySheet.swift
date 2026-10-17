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
    @State private var more = false
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
                if more { Text("Showing the first 200 records. Open a narrower/older anchor for more; this is not complete history.").font(.caption).foregroundStyle(.orange).padding(8) }
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
    private func load() async {
        busy = true; failure = nil; more = false
        do {
            switch request.tool {
            case .statistics: busy = false; return
            case .overview:
                let value = try await request.repository.overview()
                try Task.checkCancellation(); text = value
            case .reflog:
                let page = try await request.repository.reflog()
                try Task.checkCancellation(); reflog = page.entries; more = page.hasMore
            case .fileHistory:
                guard let oid = request.oid, !path.isEmpty else { busy = false; return }
                let page = try await request.repository.fileHistory(at: oid, path: GitPath(path))
                try Task.checkCancellation(); revisions = page.entries; more = page.hasMore
            case .compare:
                guard !from.isEmpty, worktree || !to.isEmpty else { busy = false; return }
                let comparison = try await request.repository.compare(from: from, to: worktree ? nil : to)
                try Task.checkCancellation()
                text = comparison.from + " → " + (comparison.to ?? "live worktree") + "\n\(comparison.files.count) files\n\n" + comparison.patch
            }
            try Task.checkCancellation(); busy = false
        } catch is CancellationError {} catch { busy = false; failure = error.localizedDescription }
    }
}
