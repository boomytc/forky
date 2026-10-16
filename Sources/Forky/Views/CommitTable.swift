import AppKit
import SwiftUI
import ForkyCore

struct CommitTable: NSViewRepresentable {
    let commits: [GitCommit]
    let graph: CommitGraph
    let decorations: [String: [GitReference]]
    @Binding var selection: String?
    let canExecute: (HistoryCommand, GitCommit) -> Bool
    let execute: (HistoryCommand, GitCommit) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        let table = NSTableView()
        table.headerView = NSTableHeaderView()
        table.rowHeight = 25
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.usesAlternatingRowBackgroundColors = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsEmptySelection = true
        table.dataSource = context.coordinator; table.delegate = context.coordinator
        table.setAccessibilityIdentifier("commitTable")
        for (id, title, width) in [("graph", "Graph", 70.0), ("subject", "Commit", 430.0),
                                   ("author", "Author", 115.0), ("sha", "SHA", 80.0), ("date", "Date", 125.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title; column.width = width
            column.minWidth = id == "subject" ? 150 : 55
            column.resizingMask = id == "subject" ? [.autoresizingMask, .userResizingMask] : [.userResizingMask]
            table.addTableColumn(column)
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = context.coordinator
        table.menu = menu
        context.coordinator.table = table
        scroll.documentView = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        let old = context.coordinator.parent
        let changed = old.commits != commits || old.graph != graph || old.decorations != decorations
        context.coordinator.parent = self
        context.coordinator.updating = true
        if let column = table.tableColumn(withIdentifier: .init("graph")) {
            column.isHidden = graph.rows.isEmpty
            if old.graph.laneCount != graph.laneCount || !context.coordinator.loaded {
                column.width = max(58, CGFloat(graph.laneCount) * 14 + 20)
            }
        }
        if changed || !context.coordinator.loaded {
            table.reloadData()
            context.coordinator.loaded = true
        }
        if let selection, let row = commits.firstIndex(where: { $0.id == selection }) {
            if table.selectedRow != row {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                table.scrollRowToVisible(row)
            }
        } else { table.deselectAll(nil) }
        context.coordinator.updating = false
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: CommitTable
        var updating = false
        var loaded = false
        weak var table: NSTableView?
        init(parent: CommitTable) { self.parent = parent }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.commits.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard parent.commits.indices.contains(row), let column = tableColumn else { return nil }
            let id = column.identifier
            let commit = parent.commits[row]
            if id.rawValue == "graph" {
                let view = tableView.makeView(withIdentifier: id, owner: self) as? GraphCell ?? GraphCell()
                view.identifier = id
                view.row = parent.graph.rows.indices.contains(row) ? parent.graph.rows[row] : nil
                view.toolTip = "Commit \(commit.shortOID) · \(commit.parents.count) parents"
                view.needsDisplay = true
                return view
            }
            if id.rawValue == "subject" {
                let cell = tableView.makeView(withIdentifier: id, owner: self) as? SubjectCell ?? SubjectCell()
                cell.identifier = id
                cell.configure(commit: commit, references: parent.decorations[commit.id] ?? [])
                return cell
            }
            let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? NSTableCellView()
            cell.identifier = id
            let field: NSTextField
            if let existing = cell.textField { field = existing }
            else {
                field = NSTextField(labelWithString: "")
                field.translatesAutoresizingMaskIntoConstraints = false; field.lineBreakMode = .byTruncatingTail
                cell.addSubview(field); cell.textField = field
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                    field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                    field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            }
            switch id.rawValue {
            case "author": field.stringValue = commit.author
            case "sha": field.stringValue = commit.shortOID
            default: field.stringValue = commit.date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
            }
            field.font = id.rawValue == "sha" ? .monospacedSystemFont(ofSize: 11, weight: .regular) : .systemFont(ofSize: 11)
            field.textColor = .secondaryLabelColor
            field.toolTip = id.rawValue == "sha" ? commit.oid : field.stringValue
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table = notification.object as? NSTableView else { return }
            let id = parent.commits.indices.contains(table.selectedRow) ? parent.commits[table.selectedRow].id : nil
            if parent.selection != id { parent.selection = id }
        }

        func menuWillOpen(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table, parent.commits.indices.contains(table.clickedRow) else { return }
            let commit = parent.commits[table.clickedRow]
            for command in HistoryCommand.allCases {
                let item = NSMenuItem(title: command.rawValue, action: #selector(performCommand(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = HistoryMenuAction(command: command, commit: commit)
                item.isEnabled = parent.canExecute(command, commit)
                menu.addItem(item)
            }
        }

        @objc private func performCommand(_ item: NSMenuItem) {
            guard let value = item.representedObject as? HistoryMenuAction else { return }
            parent.execute(value.command, value.commit)
        }
    }
}

@MainActor private enum GraphColors {
    static let values: [NSColor] = [.systemBlue, .systemGreen, .systemPurple, .systemOrange, .systemRed, .systemTeal]
    static func color(_ index: Int) -> NSColor { values[index % values.count] }
}

private final class GraphCell: NSView {
    var row: CommitGraphRow?
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let row else { return }
        func x(_ lane: Int) -> CGFloat { 12 + CGFloat(lane) * 14 }
        for segment in row.segments {
            let start = NSPoint(x: x(segment.fromLane), y: bounds.height * segment.fromLevel.rawValue)
            let end = NSPoint(x: x(segment.toLane), y: bounds.height * segment.toLevel.rawValue)
            let path = NSBezierPath()
            path.move(to: start)
            let middle = (start.y + end.y) / 2
            path.curve(to: end, controlPoint1: NSPoint(x: start.x, y: middle),
                       controlPoint2: NSPoint(x: end.x, y: middle))
            path.lineWidth = 1.6
            GraphColors.color(segment.color).setStroke(); path.stroke()
        }
        let radius: CGFloat = row.isMerge ? 4 : 3.2
        let dot = NSBezierPath(ovalIn: NSRect(x: x(row.lane) - radius, y: bounds.midY - radius,
                                             width: radius * 2, height: radius * 2))
        GraphColors.color(row.color).setFill(); dot.fill()
        if row.isMerge {
            NSColor.controlBackgroundColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: x(row.lane) - 2, y: bounds.midY - 2, width: 4, height: 4)).fill()
        }
    }
}

private final class SubjectCell: NSTableCellView {
    private let stack = NSStackView()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func configure(commit: GitCommit, references: [GitReference]) {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        let sorted = references.sorted {
            if $0.isCurrent != $1.isCurrent { return $0.isCurrent }
            return $0.fullName < $1.fullName
        }
        for reference in sorted.prefix(3) {
            let color: NSColor = reference.kind == .tag ? .systemOrange : (reference.isRemote ? .systemPurple : .systemBlue)
            let badge = NSTextField(labelWithString: (reference.isCurrent ? "✓ " : (reference.kind == .tag ? "◇ " : "")) + reference.name)
            badge.font = .systemFont(ofSize: 10, weight: .medium)
            badge.textColor = color; badge.drawsBackground = true
            badge.backgroundColor = color.withAlphaComponent(0.12)
            badge.wantsLayer = true; badge.layer?.cornerRadius = 3
            badge.lineBreakMode = .byTruncatingMiddle
            badge.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            badge.widthAnchor.constraint(lessThanOrEqualToConstant: 160).isActive = true
            badge.toolTip = reference.fullName
            stack.addArrangedSubview(badge)
        }
        if sorted.count > 3 {
            let more = NSTextField(labelWithString: "+\(sorted.count - 3)")
            more.font = .systemFont(ofSize: 10); more.textColor = .secondaryLabelColor
            stack.addArrangedSubview(more)
        }
        let subject = NSTextField(labelWithString: commit.subject)
        subject.font = .systemFont(ofSize: 12)
        subject.lineBreakMode = .byTruncatingTail
        subject.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subject.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(subject)
        toolTip = (references.map(\.fullName) + [commit.subject, commit.oid]).joined(separator: "\n")
        setAccessibilityLabel(commit.subject + " " + references.map(\.name).joined(separator: ", "))
    }
}
