import SwiftUI
import ForkyCore

/// Displays the parsed configuration owner facts; never guesses the rewritten endpoint.
struct RemoteScopeView: View {
    let remote: GitRemote
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Configured fetch URLs").font(.caption2).foregroundStyle(.secondary)
            ForEach(Array(remote.fetchURLs.enumerated()), id: \.offset) { _, url in
                Text(TransportPresentation.display(url)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            Text("Configured push destinations (all may be contacted)").font(.caption2).foregroundStyle(.secondary)
            ForEach(Array(remote.effectivePushURLs.enumerated()), id: \.offset) { _, url in
                Text(TransportPresentation.display(url)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            Text("Git/SSH rewrite and helper configuration remain effective; these are not proof of the final server endpoint.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}
