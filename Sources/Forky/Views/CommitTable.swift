import AppKit
import SwiftUI
import ForkyCore

struct CommitTable: NSViewRepresentable {
    let commits: [GitCommit]
    @Binding var selection: String?

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let table = NSTableView()
        table.headerView = NSTableHeaderView()
        table.rowHeight = 31
        table.intercellSpacing = NSSize(width: 12, height: 0)
        table.usesAlternatingRowBackgroundColors = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.allowsEmptySelection = true
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.setAccessibilityIdentifier("commitTable")
        for (id, title, width) in [("subject", "Commit", 470.0), ("author", "Author", 145.0),
                                   ("date", "Date", 115.0), ("sha", "SHA", 85.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            column.minWidth = id == "subject" ? 180 : 65
            table.addTableColumn(column)
        }
        scroll.documentView = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        let changed = context.coordinator.parent.commits != commits
        context.coordinator.parent = self
        context.coordinator.updating = true
        if changed || !context.coordinator.loaded {
            table.reloadData()
            context.coordinator.loaded = true
        }
        if let selection, let row = commits.firstIndex(where: { $0.id == selection }) {
            if table.selectedRow != row { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        } else { table.deselectAll(nil) }
        context.coordinator.updating = false
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: CommitTable
        var updating = false
        var loaded = false
        init(parent: CommitTable) { self.parent = parent }

        func numberOfRows(in tableView: NSTableView) -> Int { parent.commits.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard parent.commits.indices.contains(row), let column = tableColumn else { return nil }
            let id = column.identifier
            let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? NSTableCellView()
            cell.identifier = id
            let field: NSTextField
            if let existing = cell.textField { field = existing }
            else {
                field = NSTextField(labelWithString: "")
                field.translatesAutoresizingMaskIntoConstraints = false
                field.lineBreakMode = .byTruncatingTail
                cell.addSubview(field); cell.textField = field
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 7),
                    field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -7),
                    field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            }
            let commit = parent.commits[row]
            switch id.rawValue {
            case "author": field.stringValue = commit.author
            case "sha": field.stringValue = commit.shortOID
            case "date": field.stringValue = commit.date.formatted(.dateTime.month(.abbreviated).day().year())
            default: field.stringValue = commit.subject
            }
            field.font = id.rawValue == "sha" ? .monospacedSystemFont(ofSize: 11, weight: .regular) : .systemFont(ofSize: 12)
            field.textColor = id.rawValue == "subject" ? .labelColor : .secondaryLabelColor
            field.toolTip = id.rawValue == "subject" ? commit.subject : field.stringValue
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table = notification.object as? NSTableView else { return }
            let id = parent.commits.indices.contains(table.selectedRow) ? parent.commits[table.selectedRow].id : nil
            if parent.selection != id { parent.selection = id }
        }
    }
}
