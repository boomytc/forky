import AppKit
import SwiftUI
import ForkyCore

struct TreeSheet: View {
    let request: AdvancedRequest
    let commit: GitCommit
    let store: RepositoryStore
    var embedded = false
    @State private var folders: [GitTreeEntry] = []
    @State private var entries: [GitTreeEntry] = []
    @State private var selectedID: String?
    @State private var preview: BlobPreview?
    @State private var lines: [BlameLine]?
    @State private var blame = false
    @State private var error: String?
    @State private var fileError: String?
    @State private var loading = true
    private var selected: GitTreeEntry? { entries.first { $0.id == selectedID } }
    var body: some View {
        Group {
            if embedded { treeContent }
            else {
                AdvancedFrame(title: "File Tree / Blame", subtitle: commit.shortOID + " · " + commit.subject + " · immutable commit, not working files") {
                    treeContent
                } actions: { treeFooter }
            }
        }
        .task(id: folders.last?.oid) {
            loading = true; error = nil; entries = []; selectedID = nil
            do {
                let value = try await request.repository.tree(in: commit, directory: folders.last)
                try Task.checkCancellation(); entries = value; loading = false
            } catch is CancellationError {} catch { self.error = error.localizedDescription; loading = false }
        }
        .task(id: (selectedID ?? "") + (blame ? ":blame" : ":source")) {
            preview = nil; lines = nil; fileError = nil
            guard let selected, selected.kind == .blob else { return }
            do {
                if blame {
                    let value = try await request.repository.blame(selected); try Task.checkCancellation(); lines = value
                } else {
                    let value = try await request.repository.blob(selected); try Task.checkCancellation(); preview = value
                }
            } catch is CancellationError {} catch { fileError = error.localizedDescription }
        }
    }
    private var treeContent: some View {
            VStack(spacing: 0) {
                HStack {
                    Button("Root") { folders = [] }.disabled(folders.isEmpty)
                    Button("Up", systemImage: "chevron.up") { _ = folders.popLast() }.disabled(folders.isEmpty)
                    Text(folders.last?.path.value ?? "/").font(.system(.caption, design: .monospaced)).lineLimit(1)
                    Spacer()
                    Button("File History") {
                        if let selected { store.requestQuery(.fileHistory, path: selected.path, oid: commit.oid) }
                    }.disabled(selected?.kind != .blob).accessibilityIdentifier("treeFileHistory")
                    Toggle("Blame", isOn: $blame).toggleStyle(.button)
                        .disabled(selected?.kind != .blob || selected?.isSymlink == true).accessibilityIdentifier("showBlame")
                }.padding(10)
                Divider()
                HSplitView {
                    Group {
                        if let error { FeatureError(text: error) }
                        else if loading { ProgressView() }
                        else {
                            List(selection: $selectedID) {
                                ForEach(entries) { entry in
                                    HStack {
                                        Image(systemName: entry.kind == .tree ? "folder" : entry.isSymlink ? "link" : entry.kind == .commit ? "shippingbox" : "doc.text")
                                        Text(entry.path.name).lineLimit(1)
                                        Spacer()
                                        if entry.kind == .tree {
                                            Button("Open Folder", systemImage: "chevron.right") { folders.append(entry) }
                                                .labelStyle(.iconOnly).buttonStyle(.borderless).accessibilityIdentifier("openTree:" + entry.id)
                                        }
                                    }.tag(entry.id).help(entry.path.value)
                                }
                            }.listStyle(.inset).accessibilityIdentifier("treeEntries")
                        }
                    }.frame(minWidth: 200, idealWidth: 240, maxWidth: 300)
                    Group {
                        if let fileError { FeatureError(text: fileError) }
                        else if let selected, selected.kind == .commit { Text("Submodule commit " + selected.oid + "\nContents are not traversed.").textSelection(.enabled) }
                        else if blame, let lines {
                            List(lines) { line in
                                HStack(alignment: .top, spacing: 12) {
                                    Text("\(line.line)").frame(width: 40, alignment: .trailing).foregroundStyle(.tertiary)
                                    VStack(alignment: .leading) {
                                        Button(String(line.oid.prefix(8))) { store.revealCommit(line.oid) }
                                            .buttonStyle(.borderless).font(.system(.caption, design: .monospaced))
                                        Text(line.author + " · " + line.date.formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    }.frame(width: 125, alignment: .leading)
                                    Text(line.text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                }.help(line.oid + "\n" + line.author + " " + line.authorMail + "\n" + line.date.formatted() + "\n" + line.summary + "\nSource filename (Git): " + line.sourceFilename)
                            }.listStyle(.inset).accessibilityIdentifier("blameLines")
                        } else if !blame, let preview {
                            switch preview {
                            case .text(let text): SourceTextView(text: text, identifier: "fileContent")
                            case .binary(let count): Text("Binary / non-UTF-8 blob · \(count) bytes\nNo text decoding was substituted.").foregroundStyle(.secondary)
                            }
                        } else if selected?.kind == .blob { ProgressView("Reading captured object…") }
                        else { Text("Select a file or open a folder.").foregroundStyle(.secondary) }
                    }.frame(minWidth: 330, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
    }
    private var treeFooter: some View {
        HStack {

            Text(commit.oid).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            Spacer()
            Button("Done") { store.sheet = nil }.keyboardShortcut(.cancelAction).accessibilityIdentifier("treeDone")
        }
    }
}

struct SourceTextView: NSViewRepresentable {
    let text: String
    let identifier: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        let view = NSTextView()
        view.isEditable = false; view.isSelectable = true; view.isRichText = false
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textColor = .labelColor; view.backgroundColor = .textBackgroundColor
        view.isHorizontallyResizable = true; view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: 10_000_000, height: 10_000_000)
        view.textContainerInset = NSSize(width: 10, height: 10)
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        view.setAccessibilityIdentifier(identifier)
        if view.string != text { view.string = text }
    }
}
