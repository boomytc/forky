import SwiftUI
import ForkyCore

struct HistoryView: View {
    @Bindable var store: RepositoryStore
    @State private var summary = false
    private var title: String {
        if let ref = store.section.ref { store.snapshot?.references.first { $0.fullName == ref }?.name ?? "Reference" }
        else { "All Commits" }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label(title, systemImage: "clock.arrow.circlepath").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 8)
                FilterField(prompt: "Search commit messages", text: $store.historyQuery, identifier: "historySearch")
                    .frame(minWidth: 150, idealWidth: 230, maxWidth: 300)
                if store.isLoadingHistory { ProgressView().controlSize(.small) }
            }.padding(.horizontal, 12).frame(height: 40)
            Divider()
            if let error = store.historyError {
                EmptyPane(icon: "exclamationmark.triangle", title: "History unavailable", subtitle: error)
            } else if store.commits.isEmpty && !store.isLoadingHistory {
                EmptyPane(icon: "clock", title: store.historyQuery.isEmpty ? "A fresh start" : "No matching commits",
                          subtitle: store.historyQuery.isEmpty ? "Your first commit will appear here." : "Search covers commit messages in the selected branch/tag history, not just loaded rows.")
            } else {
                VSplitView {
                    CommitTable(commits: store.commits, graph: store.graph, decorations: store.decorations,
                                selection: Binding(get: { store.selectedCommitID }, set: store.selectCommit))
                        .frame(minHeight: 145, idealHeight: 310)
                    VStack(spacing: 0) {
                        HStack {
                            Picker("Commit Detail", selection: $summary) {
                                Text("Changes").tag(false)
                                Text("Commit").tag(true)
                            }.pickerStyle(.segmented).labelsHidden().frame(width: 180)
                            Spacer()
                            if let commit = store.selectedCommit {
                                Text(commit.shortOID).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                                Text("\(store.commitFiles.count) \(store.commitFiles.count == 1 ? "file" : "files")").font(.system(size: 11)).foregroundStyle(.secondary)
                                Menu {
                                    Button("Create Branch Here…") { store.requestBranch(startingAt: commit.oid) }
                                        .disabled(!store.canWrite)
                                    Button("Copy Commit SHA") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(commit.oid, forType: .string)
                                    }
                                } label: { Image(systemName: "ellipsis.circle") }
                                .menuStyle(.borderlessButton).fixedSize().accessibilityIdentifier("commitActions")
                            }
                        }.padding(.horizontal, 12).frame(height: 34)
                        Divider()
                        if let commit = store.selectedCommit {
                            if summary {
                                CommitSummary(commit: commit, references: store.decorations[commit.id] ?? [])
                            } else {
                                HStack(spacing: 10) {
                                    Text(commit.subject).font(.system(size: 12, weight: .medium)).lineLimit(1).help(commit.subject)
                                    Spacer(minLength: 10)
                                    Text(commit.author).font(.system(size: 11)).foregroundStyle(.secondary)
                                }.padding(.horizontal, 12).frame(height: 30)
                                Divider()
                                HSplitView {
                                    List(selection: Binding(get: { store.selectedCommitFileID }, set: store.selectCommitFile)) {
                                        ForEach(store.commitFiles) { file in
                                            HStack(spacing: 7) {
                                                Text(String(file.status.prefix(1))).font(.system(size: 10, design: .monospaced))
                                                    .foregroundStyle(file.status.hasPrefix("D") ? .red : .secondary)
                                                Text(file.path.value).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                                            }
                                            .tag(file.id).help(file.originalPath.map { "\($0.value) → \(file.path.value)" } ?? file.path.value)
                                            .contextMenu { FileContextActions(root: store.repository?.root, path: file.path) }
                                        }
                                    }
                                    .listStyle(.inset).environment(\.defaultMinListRowHeight, 25)
                                    .frame(minWidth: 155, idealWidth: 220, maxWidth: 350)
                                    .accessibilityIdentifier("commitFiles")
                                    DiffPane(store: store).frame(minWidth: 350, maxWidth: .infinity)
                                }
                            }
                        } else {
                            EmptyPane(icon: "cursorarrow", title: "Select a commit", subtitle: "Inspect its message, files and changes.")
                        }
                    }.frame(minHeight: 245)
                }
            }
            HStack(spacing: 10) {
                Text("\(store.commits.count) \(store.historyQuery.isEmpty ? "commits" : "matches") loaded")
                if !store.historyQuery.isEmpty { Text("· Graph hidden for filtered results").foregroundStyle(.tertiary) }
                Spacer()
                if store.hasMoreHistory {
                    Button("Load More") { store.loadHistory(append: true) }
                        .controlSize(.small).disabled(store.isLoadingHistory).accessibilityIdentifier("loadMoreHistory")
                }
            }
            .font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 28)
            .overlay(alignment: .top) { Divider() }
        }
        .onChange(of: store.historyQuery) { _, _ in store.loadHistory(debounce: true) }
    }
}

private struct CommitSummary: View {
    let commit: GitCommit
    let references: [GitReference]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Text(String(commit.author.prefix(2)).uppercased())
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(ForkyTheme.accent)
                        .frame(width: 42, height: 42).background(.quaternary, in: .rect(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(commit.author).font(.headline)
                        Text(commit.email).font(.callout).foregroundStyle(.secondary)
                        Text(commit.date, format: .dateTime.year().month().day().hour().minute().second()).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
                    GridRow { Text("COMMIT").foregroundStyle(.secondary); Text(commit.oid).font(.system(.caption, design: .monospaced)) }
                    GridRow { Text("PARENTS").foregroundStyle(.secondary); Text(commit.parents.isEmpty ? "Root commit" : commit.parents.joined(separator: "\n")).font(.system(.caption, design: .monospaced)) }
                    if !references.isEmpty { GridRow { Text("REFS").foregroundStyle(.secondary); Text(references.map(\.name).joined(separator: "  ·  ")) } }
                }.font(.caption)
                if commit.parents.count > 1 {
                    Label("Changes are compared with the first parent.", systemImage: "arrow.triangle.merge").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Text(commit.subject).font(.headline)
                Text(commit.body).font(.callout)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(22).textSelection(.enabled)
        }.accessibilityIdentifier("commitSummary")
    }
}
