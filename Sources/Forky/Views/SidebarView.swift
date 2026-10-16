import AppKit
import SwiftUI
import ForkyCore

struct SidebarView: View {
    @Bindable var store: RepositoryStore
    @State private var branchesExpanded = true
    @State private var remotesExpanded = true
    @State private var tagsExpanded = true

    private var selection: Binding<NavigationSection?> {
        Binding(get: { store.section }, set: { if let value = $0 { store.navigate(value) } })
    }
    private func matches(_ ref: GitReference) -> Bool {
        store.referenceQuery.isEmpty || ref.name.localizedStandardContains(store.referenceQuery)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                ForkyMark(size: 25)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.repository?.root.lastPathComponent ?? "Forky").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(store.snapshot?.branchLabel ?? "").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Menu {
                    Button("Open Repository…", action: store.chooseRepository)
                    Button("Clone Repository…") { store.requestCreation(.clone) }
                    Button("Create Repository…") { store.requestCreation(.initialize) }
                    Divider()
                    ForEach(store.recentPaths, id: \.self) { path in
                        Button(URL(fileURLWithPath: path).lastPathComponent) { store.open(URL(fileURLWithPath: path)) }
                    }
                } label: { Image(systemName: "ellipsis.circle").foregroundStyle(.secondary) }
                .menuStyle(.borderlessButton).fixedSize().help("Repositories")
            }.padding(.horizontal, 13).padding(.vertical, 13)
            Divider()
            List(selection: selection) {
                Label {
                    HStack {
                        Text("Changes")
                        Spacer()
                        Text("\(store.snapshot?.changes.count ?? 0)").foregroundStyle(.secondary).monospacedDigit()
                    }
                } icon: { Image(systemName: "doc.on.doc") }
                .tag(NavigationSection.changes).accessibilityIdentifier("changesNavigation")
                Label("All Commits", systemImage: "clock.arrow.circlepath")
                    .tag(NavigationSection.history).accessibilityIdentifier("historyNavigation")
                Label {
                    HStack {
                        Text("Stashes")
                        Spacer()
                        Text(store.tools.map { String($0.stashes.count) } ?? "?").foregroundStyle(.secondary).monospacedDigit()
                    }
                } icon: { Image(systemName: "archivebox") }
                .tag(NavigationSection.stashes).accessibilityIdentifier("stashesNavigation")
                Section {
                    FilterField(prompt: "Filter branches and tags", text: $store.referenceQuery, identifier: "referenceFilter")
                        .listRowInsets(.init(top: 4, leading: 0, bottom: 7, trailing: 0))
                    if let snapshot = store.snapshot {
                        DisclosureGroup("Branches", isExpanded: $branchesExpanded) {
                            ForEach(snapshot.branches.filter { !$0.isRemote && matches($0) }) { reference in
                                referenceRow(reference)
                            }
                            if snapshot.head == nil { Text("No commits yet").foregroundStyle(.secondary) }
                        }
                        DisclosureGroup("Remotes", isExpanded: $remotesExpanded) {
                            ForEach(snapshot.branches.filter { $0.isRemote && matches($0) }) { reference in
                                referenceRow(reference)
                            }
                            if snapshot.branches.allSatisfy({ !$0.isRemote }) { Text("No fetched branches").foregroundStyle(.tertiary) }
                            Button("Add Remote…", systemImage: "plus") { store.requestRemote(.add) }
                                .disabled(!store.canUseTools).accessibilityIdentifier("sidebarAddRemote")
                        }
                        DisclosureGroup("Tags", isExpanded: $tagsExpanded) {
                            ForEach(snapshot.tags.filter(matches)) { reference in referenceRow(reference) }
                            if snapshot.tags.isEmpty { Text("No tags").foregroundStyle(.tertiary) }
                        }
                    }
                }
            }
            .font(.system(size: 12)).listStyle(.sidebar)
            .environment(\.defaultMinListRowHeight, 25)
            .disabled(store.isMutating)
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(ForkyTheme.accent)
                Text(store.snapshot?.branchLabel ?? "HEAD").lineLimit(1).accessibilityIdentifier("currentBranch")
                Spacer()
                Button { store.requestBranch() } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).help("Create a branch at HEAD")
                    .disabled(!store.canWrite || store.snapshot?.head == nil)
                    .accessibilityLabel("New Branch")
            }
            .font(.system(size: 11)).padding(12).background(.bar).overlay(alignment: .top) { Divider() }
        }
    }

    private func referenceRow(_ reference: GitReference) -> some View {
        Label {
            HStack(spacing: 5) {
                Text(reference.name).lineLimit(1).truncationMode(.middle)
                if reference.isCurrent {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(ForkyTheme.accent)
                }
            }
        } icon: {
            Image(systemName: reference.kind == .tag ? "tag" : (reference.isRemote ? "network" : "arrow.triangle.branch"))
                .foregroundStyle(reference.isCurrent ? ForkyTheme.accent : .secondary)
        }
        .tag(NavigationSection.reference(reference.fullName))
        .accessibilityIdentifier("ref:" + reference.fullName)
        .help(reference.fullName + (reference.symbolicTarget.map { " → " + $0 } ?? (reference.kind != .tag ? " · Double-click to request checkout" : "")))
        .simultaneousGesture(TapGesture(count: 2).onEnded { store.requestBranch(reference) })
        .contextMenu {
            Button("Show History") { store.navigate(.reference(reference.fullName)) }
            if reference.kind != .tag {
                Button(reference.kind == .remoteBranch ? "Checkout as Tracking Branch…" : "Checkout Branch…") { store.requestBranch(reference) }
                    .disabled(!store.canCheckout(reference))
            }
            Divider()
            Button("Copy Reference Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(reference.fullName, forType: .string)
            }
        }
    }
}
