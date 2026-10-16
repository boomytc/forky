import SwiftUI
import ForkyCore

struct RemoteSheet: View {
    let request: RemoteRequest
    let store: RepositoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var remoteName: String
    @State private var destination: String
    @State private var setUpstream: Bool
    @State private var name = "origin"
    @State private var url: String

    init(request: RemoteRequest, store: RepositoryStore) {
        self.request = request; self.store = store
        let metadata = request.expected.collaboration.value
        _remoteName = State(initialValue: request.initialRemote ?? metadata?.tracking?.remote
                            ?? metadata?.remotes.first(where: { $0.name == "origin" })?.name ?? metadata?.remotes.first?.name ?? "")
        let upstream = metadata?.tracking?.mergeRef
        _destination = State(initialValue: upstream.map { String($0.dropFirst("refs/heads/".count)) } ?? request.expected.branch ?? "")
        _setUpstream = State(initialValue: metadata?.tracking == nil)
        let testing = ProcessInfo.processInfo.arguments.contains("--ui-testing")
        _url = State(initialValue: testing ? ProcessInfo.processInfo.environment["FORKY_UI_TEST_SOURCE"] ?? "" : "")
    }

    private var remote: GitRemote? { request.expected.collaboration.value?.remotes.first { $0.name == remoteName } }
    private var isAdd: Bool { request.action == .add }
    private var title: String {
        switch request.action {
        case .fetch: "Fetch Remote"
        case .pull: "Pull · Fast-forward Only"
        case .push: request.expected.collaboration.value?.tracking == nil ? "Publish Branch" : "Push Branch"
        case .add: "Add Remote"
        }
    }
    private var blocked: String? {
        if isAdd { return nil }
        guard let remote else { return "Choose a configured remote." }
        if let reason = remote.limitation { return reason }
        if request.action == .pull {
            guard request.expected.collaboration.value?.tracking?.remote == remote.name else {
                return "This branch does not track the selected remote. Publish it with an upstream first."
            }
            if !request.expected.changes.isEmpty { return "Commit or stash local changes before pulling." }
        }
        if request.action == .push && (request.expected.branch == nil || request.expected.head == nil) {
            return "Push requires a local branch with a commit."
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Label(title, systemImage: request.action == .push ? "arrow.up.circle" : "network").font(.title3.weight(.semibold))
            Text(request.expected.root.lastPathComponent + "  /  " + request.expected.branchLabel)
                .font(.callout).foregroundStyle(.secondary)
            if isAdd {
                TextField("Remote name", text: $name).accessibilityIdentifier("remoteName")
                TextField("HTTPS / SSH URL or local path", text: $url).accessibilityIdentifier("remoteURL")
                Text("Writes local repository configuration only. Nothing is fetched or pushed. Use a credential helper or SSH agent, not credentials in the URL.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Picker("Remote", selection: $remoteName) {
                    ForEach(request.expected.collaboration.value?.remotes ?? []) { remote in Text(remote.name).tag(remote.name) }
                }.accessibilityIdentifier("remotePicker")
                if let remote {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(request.action == .push ? "CONFIGURED PUSH DESTINATIONS" : "CONFIGURED FETCH SOURCE")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        ForEach(Array((request.action == .push ? remote.effectivePushURLs : Array(remote.fetchURLs.prefix(1))).enumerated()), id: \.offset) { _, value in
                            Text(TransportPresentation.display(value)).font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled).lineLimit(3)
                        }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: .rect(cornerRadius: 7))
                }
                if request.action == .push {
                    TextField("Destination branch", text: $destination).accessibilityIdentifier("pushDestination")
                    Toggle("Set this as the branch upstream", isOn: $setUpstream).accessibilityIdentifier("setUpstream")
                    Text("Push only the reviewed commit " + (request.expected.head.map { String($0.prefix(8)) } ?? "—")
                         + " to refs/heads/" + destination + ". No force, tags, mirror or other branches.")
                        .font(.callout).foregroundStyle(.secondary)
                } else if request.action == .pull {
                    Text("Fetch first, then fast-forward the current branch to its upstream. Divergence stops the operation. No merge commit, rebase or automatic stash.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Update this remote's tracking refs. Working files and the current branch do not change. No pruning, automatic tags or recursive submodule fetch.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let blocked { Label(blocked, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
            }
            Text("Git URL rewrite rules, SSH configuration, credential helpers and hooks remain effective. Only use repositories and remotes you trust. Terminal prompts are disabled; unavailable credentials produce an error.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isAdd ? "Add Remote" : request.action == .pull ? "Fetch & Fast-forward" : request.action == .push ? "Push Branch" : "Fetch") {
                    store.performRemote(request, remote: remote, destination: destination,
                                        setUpstream: setUpstream, name: name, url: url)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!store.canUseTools || (isAdd ? name.isEmpty || url.isEmpty : blocked != nil || (request.action == .push && destination.isEmpty)))
                .accessibilityIdentifier("remoteConfirm")
            }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 500)
    }
}
