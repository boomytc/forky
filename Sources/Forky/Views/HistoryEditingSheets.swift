import SwiftUI
import ForkyCore

struct RebaseSheet: View {
    let request: AdvancedRequest
    let base: GitCommit
    let store: RepositoryStore
    @State private var plan: RebasePlan?
    @State private var items: [RebaseItem] = []
    @State private var ontoID = ""
    @State private var acknowledged = false
    @State private var error: String?
    private var targets: [GitReference] { request.expected.references.filter { $0.symbolicTarget == nil && $0.kind != .tag && !$0.isCurrent } }
    var body: some View {
        AdvancedFrame(title: "Interactive Rebase", subtitle: "Replay commits after " + base.shortOID + " · " + request.expected.branchLabel) {
            if let error { FeatureError(text: error) }
            else if plan != nil {
                VStack(spacing: 0) {
                    HStack {
                        Picker("Onto captured commit", selection: $ontoID) {
                            Text("Same base · " + base.shortOID).tag("")
                            ForEach(targets) { ref in Text(ref.name + " · " + String(ref.objectOID.prefix(8))).tag(ref.id) }
                        }.accessibilityIdentifier("rebaseOnto")
                        Spacer()
                    }.padding(10)
                    Text("Top to bottom = replay order. Edit pauses for staged changes / rewording. Squash keeps combined messages; fixup keeps the earlier message.")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 8)
                    List {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            HStack(spacing: 10) {
                                Picker("Action", selection: $items[index].command) {
                                    ForEach(RebaseCommand.allCases, id: \.self) { command in Text(command.title).tag(command) }
                                }.labelsHidden().frame(width: 135).accessibilityIdentifier("rebaseAction:" + item.id)
                                Text(item.commit.shortOID).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                                Text(item.commit.subject).lineLimit(1)
                                Spacer()
                                Button("Up", systemImage: "arrow.up") { items.swapAt(index, index - 1) }
                                    .labelStyle(.iconOnly).disabled(index == 0).accessibilityIdentifier("rebaseUp:" + item.id)
                                Button("Down", systemImage: "arrow.down") { items.swapAt(index, index + 1) }
                                    .labelStyle(.iconOnly).disabled(index + 1 == items.count).accessibilityIdentifier("rebaseDown:" + item.id)
                            }
                        }
                    }.listStyle(.inset).accessibilityIdentifier("rebasePlan")
                    Toggle("I understand this rewrites commit identities, possibly published ones. No force push follows.", isOn: $acknowledged)
                        .font(.caption).padding(12).accessibilityIdentifier("rebaseAcknowledge")
                }
            } else { ProgressView("Validating the complete linear commit range…") }
        } actions: {
            Button("Cancel") { store.sheet = nil }.keyboardShortcut(.cancelAction)
            Spacer()
            Text("Clean worktree · linear range · ≤200 commits").font(.caption).foregroundStyle(.secondary)
            Button("Start Rebase") {
                guard let plan else { return }
                let rows = items, onto = targets.first { $0.id == ontoID }
                store.performAdvanced(request, title: "Interactive rebase · reviewed plan…") { try await $0.startRebase(plan, items: rows, onto: onto) }
            }.buttonStyle(.borderedProminent).disabled(plan == nil || !acknowledged || !store.canEditHistory).accessibilityIdentifier("rebaseConfirm")
        }
        .task {
            do {
                let value = try await request.repository.rebasePlan(after: base.oid, expected: request.expected)
                try Task.checkCancellation(); plan = value; items = value.items
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}

struct OperationSheet: View {
    let request: AdvancedRequest
    let store: RepositoryStore
    @State private var review: OperationReview?
    @State private var message = ""
    @State private var error: String?
    @State private var discard = false
    private var ready: Bool {
        guard let review else { return false }
        return !review.snapshot.hasConflicts && !review.snapshot.changes.contains { !$0.isUntracked && $0.isUnstaged }
    }
    var body: some View {
        AdvancedFrame(title: "Review Git Operation", subtitle: request.expected.root.path + " · " + (request.expected.operation.kind?.rawValue ?? "unknown")) {
            if let error { FeatureError(text: error) }
            else if let review {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Continue commits explicitly staged resolutions. Skip omits the current commit. Skip/Abort can discard tracked edits and obstructing paths; inspect the complete changed scope below. Neither action is a general rollback.")
                            .font(.callout)
                        if !ready { Label("Resolve conflicts and stage tracked worktree edits before continuing.", systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
                        if let branch = review.snapshot.operation.branchRef {
                            Text("Original branch: " + branch).font(.system(.caption, design: .monospaced))
                        }
                        if !review.snapshot.operation.supportedTodo {
                            Text("This external todo contains unsupported commands/options. Continue/Skip are unavailable; use Git or review Abort.").font(.caption).foregroundStyle(.orange)
                        }
                        Text("CHANGED SCOPE · Continue commits staged entries only").font(.caption).foregroundStyle(.secondary)
                        Text(review.snapshot.changes.isEmpty ? "No changed paths" : review.snapshot.changes.map { $0.statusLabel + "  " + $0.path.value }.joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        if review.snapshot.operation.canAmend {
                            Text("REBASE EDIT / REWORD").font(.caption).foregroundStyle(.secondary)
                            TextEditor(text: $message).font(.system(size: 12, design: .monospaced)).frame(height: 95)
                                .accessibilityIdentifier("rebaseMessage")
                            Button("Amend Paused Commit") {
                                store.performAmend(request, review: review, message: message)
                            }.disabled(!ready || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .accessibilityIdentifier("rebaseAmend")
                            if store.editDrafts[store.rewordDraftKey(request)] != nil {
                                Button("Discard Retained Message Draft") {
                                    store.editDrafts.removeValue(forKey: store.rewordDraftKey(request)); message = review.message
                                }
                            }
                            Text("Amend first, then reopen this review and Continue. Closing does not apply an edited message.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let todo = review.snapshot.operation.pendingTodo, !todo.isEmpty {
                            Text("PENDING GIT TODO · External plans may execute commands; inspect before continuing.")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(todo).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                        Divider()
                        Toggle("I approve Git discarding tracked edits and obstructing paths for Skip / Abort.", isOn: $discard)
                            .font(.caption).accessibilityIdentifier("operationDiscard")
                    }.padding(16)
                }
            } else { ProgressView("Capturing operation identity and worktree bytes…") }
        } actions: {
            Button("Cancel") { store.sheet = nil }.keyboardShortcut(.cancelAction)
            Spacer()
            Button("Abort", role: .destructive) { step(.abort) }.disabled(review == nil || !discard).accessibilityIdentifier("operationAbort")
            if request.expected.operation.kind != .merge {
                Button("Skip", role: .destructive) { step(.skip) }.disabled(review == nil || !discard || review?.snapshot.operation.supportedTodo == false).accessibilityIdentifier("operationSkip")
            }
            Button("Continue") { step(.resume) }.buttonStyle(.borderedProminent)
                .disabled(!ready || review?.snapshot.operation.supportedTodo == false || (review?.snapshot.operation.canAmend == true && message != review?.message))
                .accessibilityIdentifier("operationContinue")
        }
        .task {
            do {
                let value = try await request.repository.reviewOperation(expected: request.expected)
                try Task.checkCancellation(); review = value; message = store.editDrafts[store.rewordDraftKey(request)] ?? value.message
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    private func step(_ step: OperationStep) {
        guard let review else { return }
        store.performAdvanced(request, title: step.rawValue.capitalized + " Git operation…") { try await $0.stepOperation(review, step: step) }
    }
}
