import SwiftUI
import ForkyCore

struct SidebarView: View {
    let store: RepositoryStore

    private var selection: Binding<NavigationSection?> {
        Binding(get: { store.section }, set: { if let value = $0 { store.navigate(value) } })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ForkyMark(size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Forky").font(.headline)
                    Text("YOUR GIT WORKSPACE").font(.system(size: 8, weight: .medium)).tracking(1.3).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(.horizontal, 16).padding(.vertical, 18)

            List(selection: selection) {
                Section("Workspace") {
                    Label {
                        HStack {
                            Text("Changes")
                            Spacer()
                            Text("\(store.snapshot?.changes.count ?? 0)").foregroundStyle(.secondary).monospacedDigit()
                        }
                    } icon: { Image(systemName: "square.stack.3d.up") }
                    .tag(NavigationSection.changes).accessibilityIdentifier("changesNavigation")
                    Label("All Commits", systemImage: "clock.arrow.circlepath")
                        .tag(NavigationSection.history).accessibilityIdentifier("historyNavigation")
                }
                if let snapshot = store.snapshot {
                    Section("Local branches") {
                        ForEach(snapshot.branches.filter { !$0.isRemote }) { branch in
                            Label {
                                HStack(spacing: 5) {
                                    Text(branch.name).lineLimit(1)
                                    if branch.isCurrent { Image(systemName: "checkmark").font(.caption).foregroundStyle(ForkyTheme.accent) }
                                }
                            } icon: { Image(systemName: "arrow.triangle.branch") }
                            .tag(NavigationSection.branch(branch.fullName))
                        }
                        if snapshot.branches.allSatisfy(\.isRemote) {
                            Text(snapshot.branch ?? "No branches yet").foregroundStyle(.secondary)
                        }
                    }
                    if snapshot.branches.contains(where: \.isRemote) {
                        Section("Remote branches") {
                            ForEach(snapshot.branches.filter(\.isRemote)) { branch in
                                Label(branch.name, systemImage: "network")
                                    .tag(NavigationSection.branch(branch.fullName))
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .disabled(store.isMutating)
            Spacer(minLength: 0)
            HStack {
                Image(systemName: "internaldrive").foregroundStyle(ForkyTheme.accent)
                Text("Local first. No surprises.").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }.padding(16)
        }
    }
}
