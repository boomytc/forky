import AppKit
import SwiftUI
import ForkyCore

struct FilterField: View {
    let prompt: String
    @Binding var text: String
    let identifier: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain).accessibilityIdentifier(identifier)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("Clear filter").accessibilityLabel("Clear filter")
                    .accessibilityIdentifier(identifier + ":clear")
            }
        }
        .font(.system(size: 12)).padding(.horizontal, 8).frame(height: 27)
        .background(.quaternary, in: .rect(cornerRadius: 5))
    }
}

struct FileContextActions: View {
    let root: URL?
    let path: GitPath

    var body: some View {
        Button("Reveal in Finder", systemImage: "folder") {
            if let root { NSWorkspace.shared.activateFileViewerSelecting([root.appendingPathComponent(path.value)]) }
        }.disabled(root == nil)
        Button("Copy Relative Path", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path.value, forType: .string)
        }
    }
}

struct BranchSheet: View {
    let request: BranchRequest
    let store: RepositoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var nameFocused: Bool
    private var isCheckout: Bool { request.destination != nil }
    private var dirty: Bool { !(store.snapshot?.changes.isEmpty ?? false) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(isCheckout ? "Checkout Branch" : "Create Branch", systemImage: "arrow.triangle.branch")
                .font(.title3.weight(.semibold))
            if let destination = request.destination {
                Text("Switch from \(store.snapshot?.branchLabel ?? "HEAD") to **\(destination.name)**.")
                Label(dirty ? "Commit or move aside your local changes first." : "Working tree is clean. No force or automatic stash will be used.",
                      systemImage: dirty ? "exclamationmark.triangle" : "checkmark.shield")
                    .font(.callout).foregroundStyle(dirty ? .orange : .secondary)
            } else {
                TextField("Branch name", text: $name)
                    .textFieldStyle(.roundedBorder).focused($nameFocused)
                    .accessibilityIdentifier("branchName")
                Text("Create at \(request.head.prefix(8)). Your current branch and files will not change.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("Git hooks and configured filters may run. Open only repositories you trust.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isCheckout ? "Checkout Branch" : "Create Branch") {
                    store.performBranch(request, name: name)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!store.canWrite || (isCheckout ? dirty : name.isEmpty))
                .accessibilityIdentifier(isCheckout ? "checkoutBranchConfirm" : "createBranchConfirm")
            }
        }
        .padding(24).frame(width: 430)
        .onAppear { nameFocused = !isCheckout }
    }
}
