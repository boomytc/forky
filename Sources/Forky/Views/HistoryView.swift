import SwiftUI
import ForkyCore

struct HistoryView: View {
    let store: RepositoryStore
    private var title: String {
        if case .branch(let ref) = store.section { String(ref.split(separator: "/").dropFirst(2).joined(separator: "/")) }
        else { "All Commits" }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(title, systemImage: "clock.arrow.circlepath").font(.headline)
                Spacer()
                Text("\(store.commits.count) loaded").font(.caption).foregroundStyle(.secondary)
                if store.isLoadingHistory { ProgressView().controlSize(.small) }
                if store.hasMoreHistory {
                    Button("Load More") { store.loadHistory(append: true) }
                        .controlSize(.small).disabled(store.isLoadingHistory)
                }
            }.padding(.horizontal, 16).frame(height: 49)
            Divider()
            if let error = store.historyError {
                EmptyPane(icon: "exclamationmark.triangle", title: "History unavailable", subtitle: error)
            } else if store.commits.isEmpty && !store.isLoadingHistory {
                EmptyPane(icon: "clock", title: "A fresh start", subtitle: "Your first commit will appear here.")
            } else {
                VSplitView {
                    CommitTable(commits: store.commits,
                                selection: Binding(get: { store.selectedCommitID }, set: store.selectCommit))
                        .frame(minHeight: 160, idealHeight: 290)
                    VStack(spacing: 0) {
                        if let commit = store.selectedCommit {
                            CommitHeader(commit: commit)
                            Divider()
                        }
                        HSplitView {
                            List(selection: Binding(get: { store.selectedCommitFileID }, set: store.selectCommitFile)) {
                                ForEach(store.commitFiles) { file in
                                    HStack(spacing: 8) {
                                        Text(String(file.status.prefix(1)))
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundStyle(file.status.hasPrefix("D") ? .red : ForkyTheme.accent)
                                        Text(file.path.value).font(.callout).lineLimit(1).truncationMode(.middle)
                                    }.padding(.vertical, 4).tag(file.id)
                                }
                            }
                            .listStyle(.inset).frame(minWidth: 180, idealWidth: 245, maxWidth: 360)
                            .accessibilityIdentifier("commitFiles")
                            DiffPane(store: store).frame(minWidth: 350, maxWidth: .infinity)
                        }
                    }.frame(minHeight: 240)
                }
            }
        }
    }
}

private struct CommitHeader: View {
    let commit: GitCommit
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(commit.subject).font(.headline).textSelection(.enabled)
            HStack(spacing: 12) {
                Label(commit.author, systemImage: "person")
                Text(commit.date, format: .dateTime.year().month().day().hour().minute())
                Text(commit.shortOID).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                if commit.parents.count > 1 { Text("Merge · diff against first parent").foregroundStyle(.orange) }
            }.font(.caption).foregroundStyle(.secondary)
            if !commit.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(commit.body).font(.callout).lineLimit(3).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
    }
}
