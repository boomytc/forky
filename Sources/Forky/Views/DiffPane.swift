import AppKit
import SwiftUI
import ForkyCore

enum DiffMode: String, CaseIterable { case unified, split }

struct DiffPane: View {
    @Bindable var store: RepositoryStore
    @State private var hunk = -1
    @State private var inline: InlinePatchRequest?
    private var hunkCount: Int { store.diff.lines.filter { $0.kind == .hunk }.count }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text").foregroundStyle(.secondary)
                Text(store.diffTitle ?? "Diff Preview").font(.system(size: 11, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    .help(store.diffTitle ?? "")
                Spacer(minLength: 4)
                if store.section == .changes, let selected = store.selectedChange,
                   let file = store.snapshot?.changes.first(where: { $0.id == selected.path }) {
                    if file.isConflict {
                        Button("Resolve…") { store.requestAdvanced(.conflict(file)) }
                            .disabled(!store.canWrite).accessibilityIdentifier("resolveConflict")
                    } else if file.canReviewPartial(on: selected.side) {
                        Button(selected.side == .worktree ? "Stage Lines…" : "Unstage Lines…") { store.requestAdvanced(.partial(file, selected.side)) }
                            .disabled(!store.canWrite).accessibilityIdentifier("partialStage")
                    }
                }
                Menu {
                    Toggle("Whole file context", isOn: $store.diffOptions.wholeFile)
                    Toggle("Ignore whitespace (display only)", isOn: $store.diffOptions.ignoreWhitespace)
                    Toggle("Wrap lines", isOn: $store.diffOptions.wrap)
                    Toggle("Show spaces / tabs", isOn: $store.diffOptions.showWhitespace)
                    Button("More context") { store.diffOptions.context = min(100, store.diffOptions.context + 5) }
                    Button("Less context") { store.diffOptions.context = max(0, store.diffOptions.context - 5) }
                    if store.section == .changes, let selected = store.selectedChange,
                       let file = store.snapshot?.changes.first(where: { $0.id == selected.path }),
                       file.canReviewPartial(on: selected.side), let repository = store.repository, let expected = store.snapshot {
                        Button("Inline Staging Review") { inline = InlinePatchRequest(repository: repository, expected: expected, file: file, side: selected.side) }
                        if selected.side == .worktree { Button("Discard Working Lines…", role: .destructive) { store.requestAdvanced(.discard(file)) } }
                    }
                } label: { Image(systemName: "text.magnifyingglass") }.menuStyle(.borderlessButton).fixedSize().accessibilityIdentifier("diffTools")
                Button { hunk = max(0, hunk - 1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.plain).disabled(hunkCount == 0)
                Button { hunk = min(max(0, hunkCount - 1), hunk + 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.plain).disabled(hunkCount == 0)
                if store.diff.additions > 0 { Text("+\(store.diff.additions)").foregroundStyle(.green).monospacedDigit() }
                if store.diff.deletions > 0 { Text("−\(store.diff.deletions)").foregroundStyle(.red).monospacedDigit() }
                Picker("Diff Layout", selection: $store.diffMode) {
                    Text("Unified").tag(DiffMode.unified)
                    Text("Split").tag(DiffMode.split)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 126).accessibilityIdentifier("diffLayout")
            }.font(.system(size: 10)).padding(.horizontal, 10).frame(height: 34)
            Divider()
            if store.diffMode == .split && store.diffTitle != nil {
                HStack {
                    Text(store.selectedChange?.side == .worktree && store.section == .changes ? "Index / before" : "Before")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("After").frame(maxWidth: .infinity, alignment: .leading)
                }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 23)
                Divider()
            }
            if let inline {
                InlinePatchView(request: inline, store: store, close: { self.inline = nil })
            } else if store.isLoadingDetail {
                ProgressView("Loading diff…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = store.diffError {
                EmptyPane(icon: "exclamationmark.triangle", title: "Preview unavailable", subtitle: error)
            } else if store.diffTitle == nil {
                EmptyPane(icon: "rectangle.split.2x1", title: "A closer look", subtitle: "Select a changed file to inspect its diff.")
            } else if store.diff.text.isEmpty {
                EmptyPane(icon: "doc", title: "No text diff", subtitle: "The selected file has no text changes to display. File modes or binary content may have changed.")
            } else {
                DiffTextView(document: store.diff, mode: store.diffMode, options: store.diffOptions, hunk: hunk).accessibilityIdentifier("diffPreview")
            }
            if store.diff.truncated {
                Label("Preview truncated at 500,000 characters. Use a dedicated diff tool for the complete change.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.orange).padding(8)
            }
        }.background(ForkyTheme.panel)
        .onChange(of: store.diffOptions) { _, _ in store.diffSettingsChanged() }
        .onChange(of: store.diffTitle) { _, _ in inline = nil; hunk = -1 }
    }
}

private struct DiffTextView: NSViewRepresentable {
    let document: DiffDocument
    let mode: DiffMode
    let options: DiffOptions
    let hunk: Int
    @Environment(\.colorScheme) private var colorScheme
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> DiffSurface {
        let surface = DiffSurface()
        context.coordinator.surface = surface
        for scroll in [surface.left, surface.right] {
            scroll.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.scrolled(_:)),
                                                   name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        }
        return surface
    }

    func updateNSView(_ surface: DiffSurface, context: Context) {
        let coordinator = context.coordinator
        if coordinator.document == document && coordinator.scheme == colorScheme && coordinator.mode == mode && coordinator.options == options {
            if coordinator.hunk != hunk { coordinator.hunk = hunk; surface.jump(to: hunk) }
            return
        }
        coordinator.updating = true
        defer { coordinator.updating = false }
        coordinator.document = document; coordinator.scheme = colorScheme; coordinator.mode = mode
        coordinator.options = options; coordinator.hunk = hunk; surface.options = options
        surface.right.isHidden = mode == .unified
        surface.left.hasVerticalScroller = mode == .unified
        if mode == .split {
            let split = SplitDiff(document: document)
            surface.render(split.rows.map(\.old), in: surface.left, numbers: .old)
            surface.render(split.rows.map(\.new), in: surface.right, numbers: .new)
        } else {
            surface.render(document.lines.map(Optional.some), in: surface.left, numbers: .both)
        }
        surface.jump(to: hunk)
    }

    @MainActor final class Coordinator: NSObject {
        var options = DiffOptions()
        var hunk = 0
        var document: DiffDocument?
        var scheme: ColorScheme?
        var mode: DiffMode?
        var updating = false
        weak var surface: DiffSurface?
        deinit { NotificationCenter.default.removeObserver(self) }

        @objc func scrolled(_ notification: Notification) {
            guard mode == .split, !updating, let surface, let source = notification.object as? NSClipView else { return }
            let target = source === surface.left.contentView ? surface.right : surface.left
            guard abs(target.contentView.bounds.origin.y - source.bounds.origin.y) > 0.5 else { return }
            updating = true
            var rect = target.contentView.bounds
            rect.origin.y = source.bounds.origin.y
            target.contentView.scroll(to: target.contentView.constrainBoundsRect(rect).origin)
            target.reflectScrolledClipView(target.contentView)
            updating = false
        }
    }
}

private enum DiffNumberColumns { case both, old, new }

private final class DiffSurface: NSView {
    var options = DiffOptions()
    private var hunkRanges: [ObjectIdentifier: [NSRange]] = [:]
    func jump(to index: Int) {
        guard index >= 0 else { return }
        for scroll in [left, right] where !scroll.isHidden {
            if let text = scroll.documentView as? NSTextView, let ranges = hunkRanges[ObjectIdentifier(scroll)], ranges.indices.contains(index) {
                text.scrollRangeToVisible(ranges[index])
            }
        }
    }
    let left = DiffSurface.makeScroll(identifier: "diffText", label: "Unified diff or old version")
    let right = DiffSurface.makeScroll(identifier: "diffTextNew", label: "New version")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let stack = NSStackView(views: [left, right])
        stack.orientation = .horizontal; stack.distribution = .fillEqually; stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private static func makeScroll(identifier: String, label: String) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let text = NSTextView()
        text.isEditable = false; text.isSelectable = true; text.isRichText = false; text.allowsUndo = false
        text.usesFindPanel = true
        text.isAutomaticLinkDetectionEnabled = false; text.isAutomaticSpellingCorrectionEnabled = false
        text.backgroundColor = .controlBackgroundColor
        text.textContainerInset = NSSize(width: 9, height: 10)
        text.isHorizontallyResizable = true; text.isVerticallyResizable = true
        text.minSize = .zero; text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.containerSize = text.maxSize; text.textContainer?.widthTracksTextView = false
        text.setAccessibilityLabel(label); text.setAccessibilityIdentifier(identifier)
        scroll.documentView = text
        return scroll
    }

    func render(_ lines: [DiffLine?], in scroll: NSScrollView, numbers: DiffNumberColumns) {
        guard let text = scroll.documentView as? NSTextView else { return }
        let output = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 2
        text.isHorizontallyResizable = !options.wrap
        text.textContainer?.widthTracksTextView = options.wrap
        text.textContainer?.containerSize.width = options.wrap ? scroll.contentSize.width : CGFloat.greatestFiniteMagnitude
        text.autoresizingMask = options.wrap ? [.width] : []
        var hunks: [NSRange] = []
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        for line in lines {
            let color: NSColor, background: NSColor
            switch line?.kind {
            case .addition: color = .systemGreen; background = NSColor.systemGreen.withAlphaComponent(0.09)
            case .deletion: color = .systemRed; background = NSColor.systemRed.withAlphaComponent(0.08)
            case .hunk: color = .systemTeal; background = NSColor.systemTeal.withAlphaComponent(0.07)
            case .header: color = .secondaryLabelColor; background = .clear
            default: color = .labelColor; background = .clear
            }
            func number(_ value: Int?) -> String {
                let string = value.map(String.init) ?? ""
                return String(repeating: " ", count: max(0, 5 - string.count)) + string
            }
            let gutter: String
            switch numbers {
            case .old: gutter = number(line?.oldNumber) + "  "
            case .new: gutter = number(line?.newNumber) + "  "
            case .both: gutter = number(line?.oldNumber) + " " + number(line?.newNumber) + "  "
            }
            if line?.kind == .hunk { hunks.append(NSRange(location: output.length, length: 1)) }
            output.append(NSAttributedString(string: gutter, attributes: [
                .font: font, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: paragraph, .backgroundColor: background
            ]))
            let body = options.showWhitespace ? (line?.text ?? "").replacingOccurrences(of: "\t", with: "⇥   ").replacingOccurrences(of: " ", with: "·") : (line?.text ?? "")
            output.append(NSAttributedString(string: body + "\n", attributes: [
                .font: font, .foregroundColor: color, .backgroundColor: background, .paragraphStyle: paragraph
            ]))
        }
        hunkRanges[ObjectIdentifier(scroll)] = hunks
        text.textStorage?.setAttributedString(output)
        text.scrollToBeginningOfDocument(nil)
    }
}
