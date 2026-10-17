import SwiftUI
import ForkyCore

struct ResetSheet: View {
    let request: ManagementRequest
    let store: RepositoryStore
    @State private var mode = ResetMode.soft
    @State private var review: ResetReview?
    @State private var approved = false
    @State private var discard = false
    @State private var failure: String?
    var body: some View {
        AdvancedFrame(title: "Reset Current Branch", subtitle: request.expected.root.path + " · " + request.expected.branchLabel) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Move HEAD from " + (request.expected.head ?? "(none)") + " to " + (request.commitOID ?? "(none)")).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Picker("Mode", selection: $mode) { ForEach(ResetMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                Text(mode == .soft ? "Keep the current index and working files." : mode == .mixed ? "Replace the index with the target; working files stay unchanged." : "PERMANENTLY replace tracked working files and index. Untracked data causes refusal. A reflog/backup ref does not save unstaged file contents.")
                    .foregroundStyle(mode == .hard ? .orange : .secondary)
                if let review {
                    Text("\(review.changes.count) changed paths observed before reset. Review the complete scope below.")
                    List(review.changes) { Text($0.statusLabel + " · " + $0.path.value).font(.caption) }.frame(maxHeight: 90)
                    SourceTextView(text: review.patch, identifier: "resetPatch")
                } else if let failure { FeatureError(text: failure) } else { ProgressView() }
                Toggle("I approve moving this branch / HEAD and changing the index according to the selected mode.", isOn: $approved).accessibilityIdentifier("resetApprove")
                if mode == .hard { Toggle("I explicitly approve losing the reviewed tracked working changes.", isOn: $discard).accessibilityIdentifier("hardDiscard") }
            }.padding(14)
        } actions: {
            Button("Cancel") { store.sheet = nil }.keyboardShortcut(.cancelAction)
            Spacer()
            Button("Apply Reviewed Reset") {
                guard let review else { return }
                let approval = discard
                store.performManagement(request, title: "Resetting reviewed branch…") { try await $0.reset(review, approveHardDiscard: approval) }
            }.disabled(review == nil || !approved || (mode == .hard && !discard) || !store.canWrite).accessibilityIdentifier("resetConfirm")
        }
        .task(id: mode) {
            review = nil; approved = false; discard = false; failure = nil
            guard let oid = request.commitOID else { failure = "Select a target commit first."; return }
            do {
                let value = try await request.repository.reviewReset(to: oid, mode: mode, expected: request.expected)
                try Task.checkCancellation(); review = value
            } catch is CancellationError {} catch { failure = error.localizedDescription }
        }
    }
}
