import SwiftUI
import AppKit
import ForkyCore

struct CreationSheet: View {
    let kind: CreationKind
    let store: RepositoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var source: String
    @State private var name = ""
    @State private var branch = "main"
    @State private var parent: URL?

    init(kind: CreationKind, store: RepositoryStore) {
        self.kind = kind; self.store = store
        let testing = ProcessInfo.processInfo.arguments.contains("--ui-testing")
        let env = ProcessInfo.processInfo.environment
        _source = State(initialValue: testing ? env["FORKY_UI_TEST_SOURCE"] ?? "" : "")
        _parent = State(initialValue: testing ? env["FORKY_UI_TEST_PARENT"].map { URL(fileURLWithPath: $0, isDirectory: true) } : nil)
    }

    private var destination: URL? {
        guard let parent, !name.isEmpty, ![".", ".."].contains(name),
              !name.contains("/"), !name.contains("\0"), !name.contains("\n") else { return nil }
        return parent.appendingPathComponent(name, isDirectory: true)
    }
    private var exists: Bool { destination.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Label(kind == .clone ? "Clone Repository" : "Create Repository",
                  systemImage: kind == .clone ? "square.and.arrow.down" : "folder.badge.plus").font(.title3.weight(.semibold))
            if kind == .clone {
                TextField("HTTPS / SSH URL or absolute local source path", text: $source).accessibilityIdentifier("cloneSource")
            } else {
                TextField("Initial branch", text: $branch).accessibilityIdentifier("creationBranch")
            }
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("LOCATION").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    Text(parent?.path ?? "Choose a parent folder").font(.callout).lineLimit(2).textSelection(.enabled)
                }
                Spacer()
                Button("Choose Folder…") { chooseParent() }.accessibilityIdentifier("creationChooseParent")
            }.padding(12).background(.quaternary, in: .rect(cornerRadius: 7))
            TextField("New folder name", text: $name).accessibilityIdentifier("creationName")
            if let destination {
                Text(destination.path).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if exists { Label("This location already exists. Choose a new folder name.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout) }
            Text(kind == .clone
                 ? "Clone into a new folder, then open it. No recursive submodules or local hardlinks. Git transport rules, credentials, templates and checkout hooks may run."
                 : "Create a new local Git repository, then open it. Existing folders are never adopted or overwritten. Git's configured templates remain effective.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Interrupted creation is not automatically removed. Inspect the destination before retrying.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(kind == .clone ? "Clone & Open" : "Create & Open") {
                    guard let destination else { return }
                    store.performCreation(kind == .clone ? .clone(source) : .initialize(branch), at: destination)
                    dismiss()
                }.buttonStyle(.borderedProminent)
                    .disabled(store.isBusy || destination == nil || exists || (kind == .clone ? source.isEmpty : branch.isEmpty))
                    .accessibilityIdentifier("creationConfirm")
            }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 500)
    }

    private func chooseParent() {
        let panel = NSOpenPanel()
        panel.title = "Choose the parent folder"; panel.prompt = "Choose"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.begin { response in if response == .OK { parent = panel.url } }
    }
}
