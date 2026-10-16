import SwiftUI

struct OperationStrip: View {
    let store: RepositoryStore
    var body: some View {
        if store.isMutating {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.activity).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text("Do not close Forky. Cancellation does not undo completed Git changes.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel Operation", action: store.cancelOperation)
                    .controlSize(.small).disabled(!store.canCancelOperation).accessibilityIdentifier("cancelOperation")
            }.padding(.horizontal, 14).padding(.vertical, 10).background(.quaternary)
            Divider()
        }
    }
}

struct ActivityView: View {
    let store: RepositoryStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Repository Activity", systemImage: "clock.arrow.circlepath").font(.title3.weight(.semibold))
            Text("Last 30 explicit operations in this session. Not a rollback journal.")
                .font(.callout).foregroundStyle(.secondary)
            if store.operations.isEmpty {
                ContentUnavailableView("No operations yet", systemImage: "checkmark.circle",
                                       description: Text("Your confirmed Git operations will appear here."))
            } else {
                List(store.operations) { operation in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: icon(operation.outcome)).foregroundStyle(color(operation.outcome))
                            Text(operation.title).font(.system(size: 12, weight: .medium))
                            Spacer()
                            Text(operation.started, style: .time).font(.caption).foregroundStyle(.secondary)
                        }
                        if let root = operation.repositoryRoot {
                            Text(root.path).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle).help(root.path)
                        }
                        if !operation.detail.isEmpty {
                            Text(operation.detail).font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }.padding(.vertical, 6)
                }.listStyle(.inset)
            }
            Divider()
            HStack {
                if store.canCancelOperation { Button("Cancel Git Operation", action: store.cancelOperation) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).accessibilityIdentifier("activityDone")
            }
        }.padding(24).frame(width: 660, height: 460)
    }
    private func icon(_ state: OperationRecord.Outcome) -> String {
        switch state { case .running: "hourglass"; case .succeeded: "checkmark.circle"; case .failed: "exclamationmark.triangle"; case .cancelled: "stop.circle" }
    }
    private func color(_ state: OperationRecord.Outcome) -> Color {
        switch state { case .running: .secondary; case .succeeded: .green; case .failed: .orange; case .cancelled: .secondary }
    }
}
