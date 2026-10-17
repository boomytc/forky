import AppKit
import SwiftUI

enum PathSelection { case inputFile, outputFile, executable, newDirectory }
struct AbsolutePathField: View {
    let title: String
    @Binding var value: String
    let selection: PathSelection
    var body: some View {
        HStack {
            TextField(title, text: $value).textFieldStyle(.roundedBorder)
            Button("Choose…", action: choose)
        }
    }
    private func choose() {
        if selection == .outputFile {
            let panel = NSSavePanel()
            panel.title = title; panel.canCreateDirectories = false
            panel.begin { result in
                if result == .OK, let url = panel.url { value = url.path }
            }
        } else {
            let panel = NSOpenPanel()
            panel.title = title; panel.allowsMultipleSelection = false; panel.canCreateDirectories = false
            panel.canChooseDirectories = selection == .newDirectory
            panel.canChooseFiles = selection != .newDirectory
            panel.begin { result in
                guard result == .OK, let url = panel.url else { return }
                value = selection == .newDirectory ? url.appendingPathComponent("Forky Worktree").path : url.path
            }
        }
    }
}
