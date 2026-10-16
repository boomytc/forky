import AppKit
import SwiftUI
import ForkyCore

struct DiffPane: View {
    let store: RepositoryStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text").foregroundStyle(.secondary)
                Text(store.selectedFileName ?? "Diff Preview").font(.system(.callout, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer()
                if store.diff.additions > 0 { Text("+\(store.diff.additions)").foregroundStyle(.green).monospacedDigit() }
                if store.diff.deletions > 0 { Text("−\(store.diff.deletions)").foregroundStyle(.red).monospacedDigit() }
                if store.section == .changes, let side = store.selectedChange?.side {
                    Text(side == .staged ? "STAGED" : "WORKTREE")
                        .font(.system(size: 9, weight: .semibold)).tracking(0.7)
                        .foregroundStyle(.secondary).padding(.horizontal, 7).padding(.vertical, 4)
                        .background(.quaternary, in: .rect(cornerRadius: 4))
                }
            }.font(.caption).padding(.horizontal, 16).frame(height: 49)
            Divider()
            if store.isLoadingDetail {
                ProgressView("Loading diff…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = store.diffError {
                EmptyPane(icon: "exclamationmark.triangle", title: "Preview unavailable", subtitle: error)
            } else if store.selectedFileName == nil {
                EmptyPane(icon: "rectangle.split.2x1", title: "A closer look", subtitle: "Select a changed file to inspect its diff.")
            } else if store.diff.text.isEmpty {
                EmptyPane(icon: "doc", title: "No text diff", subtitle: "The selected file has no text changes to display. File modes or binary content may have changed.")
            } else {
                DiffTextView(document: store.diff).accessibilityIdentifier("diffPreview")
            }
            if store.diff.truncated {
                Label("Preview truncated at 500,000 characters. Open a dedicated diff tool for the complete change.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.orange).padding(10)
            }
        }
        .background(ForkyTheme.panel)
    }
}

private struct DiffTextView: NSViewRepresentable {
    let document: DiffDocument
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let text = NSTextView()
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.allowsUndo = false
        text.usesFindPanel = true
        text.isAutomaticLinkDetectionEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.backgroundColor = .controlBackgroundColor
        text.textContainerInset = NSSize(width: 14, height: 16)
        text.isHorizontallyResizable = true
        text.isVerticallyResizable = true
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.containerSize = text.maxSize
        text.textContainer?.widthTracksTextView = false
        text.setAccessibilityLabel("Unified diff")
        text.setAccessibilityIdentifier("diffText")
        scroll.documentView = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard context.coordinator.document != document || context.coordinator.scheme != colorScheme,
              let text = scroll.documentView as? NSTextView else { return }
        context.coordinator.document = document
        context.coordinator.scheme = colorScheme
        let output = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        for line in document.lines {
            let color: NSColor
            let background: NSColor
            switch line.kind {
            case .addition: color = .systemGreen; background = NSColor.systemGreen.withAlphaComponent(0.08)
            case .deletion: color = .systemRed; background = NSColor.systemRed.withAlphaComponent(0.07)
            case .hunk: color = .systemTeal; background = NSColor.systemTeal.withAlphaComponent(0.07)
            case .header: color = .secondaryLabelColor; background = .clear
            case .context: color = .labelColor; background = .clear
            }
            func number(_ value: Int?) -> String {
                let string = value.map(String.init) ?? ""
                return String(repeating: " ", count: max(0, 5 - string.count)) + string
            }
            let gutter = "\(number(line.oldNumber)) \(number(line.newNumber))  "
            output.append(NSAttributedString(string: gutter, attributes: [
                .font: font, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: paragraph,
                .backgroundColor: background
            ]))
            output.append(NSAttributedString(string: line.text + "\n", attributes: [
                .font: font, .foregroundColor: color, .backgroundColor: background, .paragraphStyle: paragraph
            ]))
        }
        text.textStorage?.setAttributedString(output)
        text.scrollToBeginningOfDocument(nil)
    }

    final class Coordinator {
        var document: DiffDocument?
        var scheme: ColorScheme?
    }
}
