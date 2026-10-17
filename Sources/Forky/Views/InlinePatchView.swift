import SwiftUI
import ForkyCore

struct InlinePatchRequest: Identifiable {
    let id = UUID()
    let repository: GitRepository
    let expected: RepositorySnapshot
    let file: FileChange
    let side: DiffSide
}
struct InlinePatchView: View {
    let request: InlinePatchRequest
    let store: RepositoryStore
    let close: () -> Void
    @State private var review: PartialReview?
    @State private var selection = Set<Int>()
    @State private var error: String?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(request.side == .staged ? "Index → HEAD selection to unstage" : "Index → worktree selection to stage").font(.caption)
                Spacer()
                Button("Close", action: close)
                Button("Apply Selected Lines") {
                    guard let review else { return }
                    let selected = selection
                    store.mutate("Applying inline reviewed patch…") { try await $0.applyPartial(review, selected: selected) }
                    close()
                }.disabled(selection.isEmpty || !store.canWrite).buttonStyle(.borderedProminent)
            }.padding(10)
            if let error { FeatureError(text: error) }
            else if let review {
                List {
                    ForEach(review.patch.hunks) { hunk in
                        Section {
                            ForEach(hunk.lines) { line in
                                HStack {
                                    if line.isChange {
                                        Toggle("", isOn: Binding(get: { selection.contains(line.id) }, set: { if $0 { selection.insert(line.id) } else { selection.remove(line.id) } })).labelsHidden().accessibilityIdentifier("inlinePatchLine:\(line.id)")
                                    }
                                    Text((line.kind == .addition ? "+" : line.kind == .deletion ? "−" : " ") + line.text)
                                        .font(.system(.caption, design: .monospaced)).foregroundStyle(line.kind == .addition ? .green : line.kind == .deletion ? .red : .secondary)
                                }
                            }
                        } header: {
                            HStack {
                                Text(hunk.header)
                                Spacer()
                                Button("Select Hunk") { selection.formUnion(hunk.changeIDs) }.buttonStyle(.borderless)
                            }
                        }
                    }
                }
            } else { ProgressView("Reading exact complete patch…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .task(id: request.id) {
            do {
                let value = try await request.repository.reviewPartial(request.file, side: request.side, expected: request.expected)
                try Task.checkCancellation(); review = value
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}
