import SwiftUI
import ForkyCore

struct IntegrationSheet: View {
    let request: ManagementRequest
    let store: RepositoryStore
    @State private var useRebase = false
    @State private var mode = MergeMode.fastForward
    @State private var approved = false
    @State private var base: GitCommit?
    @State private var failure: String?
    private var target: GitReference? {
        guard let oid = request.expected.collaboration.value?.tracking?.upstreamOID,
              let name = request.expected.collaboration.value?.tracking?.upstream else { return nil }
        return request.expected.references.first { $0.fullName == name && $0.commitOID == oid && $0.symbolicTarget == nil }
    }
    var body: some View {
        if useRebase, let base, let target {
            RebaseSheet(request: AdvancedRequest(repository: request.repository, expected: request.expected, action: .rebase(base)),
                        base: base, store: store, initialOntoID: target.id)
        } else {
            AdvancedFrame(title: "Integrate Fetched Upstream", subtitle: request.expected.root.path + " · " + request.expected.branchLabel) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("This uses locally observed tracking state, not current server state. Fetch first if you need an updated destination. Nothing here fetches or autostashes.")
                    Text("Source: " + (target?.fullName ?? "(no known upstream)") + "\nOID: " + (target?.commitOID ?? "(unavailable)"))
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Text("Destination HEAD: " + (request.expected.head ?? "(unborn)")).font(.system(.caption, design: .monospaced))
                    Picker("Merge mode", selection: $mode) { ForEach(MergeMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    Text("Or choose Rebase below to review the complete local linear range after its merge base. Existing conflict/Continue/Abort handling is shared.")
                    if let failure { Text(failure).foregroundStyle(.orange) }
                    Toggle("I reviewed these immutable source/destination commits and selected merge effects.", isOn: $approved)
                }.padding(18)
            } actions: {
                Button("Cancel") { store.sheet = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Review Rebase Plan") { useRebase = true }.disabled(target == nil || !store.canEditHistory)
                Button("Apply Reviewed Merge") {
                    guard let oid = target?.commitOID else { return }
                    let mode = mode
                    store.performManagement(request, title: "Integrating reviewed upstream…") { try await $0.merge(oid, mode: mode, expected: request.expected) }
                }.disabled(target == nil || !approved || !store.canEditHistory).buttonStyle(.borderedProminent)
            }
            .onChange(of: mode) { _, _ in approved = false }
            .task(id: useRebase) {
                guard useRebase, let target else { return }
                do {
                    let value = try await request.repository.integrationBase(onto: target, expected: request.expected)
                    try Task.checkCancellation(); base = value
                } catch is CancellationError {} catch { failure = error.localizedDescription; useRebase = false }
            }
        }
    }
}
