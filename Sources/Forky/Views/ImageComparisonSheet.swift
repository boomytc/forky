import SwiftUI
import ImageIO
import ForkyCore

private enum ImageLayout: String, CaseIterable { case sideBySide = "Side by Side", swipe = "Swipe", onion = "Onion Skin" }
private enum ImageThumbnail {
    static func make(_ bytes: Data?) throws -> CGImage? {
        guard let bytes else { return nil }
        guard let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value,
              let h = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value,
              w > 0, h > 0, w <= 32768, h <= 32768, w <= 64_000_000 / h else {
            throw GitError.invalidInput("Not a supported first-frame image, or dimensions exceed the 64-million-pixel decode budget.")
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2048,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: false] as CFDictionary) else {
            throw GitError.invalidInput("Image thumbnail could not be decoded.")
        }
        return image
    }
}
struct ImageComparisonSheet: View {
    let request: ManagementRequest
    let store: RepositoryStore
    @State private var path = ""
    @State private var from = ""
    @State private var to = ""
    @State private var worktree = true
    @State private var layout = ImageLayout.sideBySide
    @State private var fraction = 0.5
    @State private var before: CGImage?
    @State private var after: CGImage?
    @State private var failure: String?
    @State private var busy = false
    @State private var captured = false
    @State private var captureScope = ""
    @State private var token = UUID()
    var body: some View {
        AdvancedFrame(title: "Image Comparison", subtitle: "Captured local bytes · first frame · thumbnails ≤2048 px · no LFS hydration or checkout") {
            VStack(spacing: 10) {
                HStack {
                    TextField("Relative image path", text: $path)
                    Button("Capture") { token = UUID() }.disabled(busy || path.isEmpty)
                }
                HStack {
                    TextField("Before commit OID", text: $from)
                    Toggle("After = working file", isOn: $worktree)
                    if !worktree { TextField("After commit OID", text: $to) }
                }
                Picker("Layout", selection: $layout) { ForEach(ImageLayout.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                if layout != .sideBySide { Slider(value: $fraction, in: 0...1) }
                if busy { ProgressView() }
                else if let failure { FeatureError(text: failure) }
                else if !captured { ContentUnavailableView("Choose a path and Capture", systemImage: "photo") }
                else if layout == .sideBySide {
                    HStack { picture(before, label: "Before"); Divider(); picture(after, label: "After") }
                } else if layout == .onion {
                    ZStack { picture(before, label: "Before"); picture(after, label: "After").opacity(fraction) }
                } else {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            picture(before, label: "Before").frame(width: proxy.size.width, height: proxy.size.height)
                            picture(after, label: "After").frame(width: proxy.size.width, height: proxy.size.height)
                                .mask(alignment: .leading) { Rectangle().frame(width: proxy.size.width * fraction) }
                            Rectangle().fill(.tint).frame(width: 2).offset(x: proxy.size.width * fraction)
                        }
                    }
                }
                if captured { Text("Captured: " + captureScope).font(.caption2).textSelection(.enabled).accessibilityIdentifier("imageCaptureComplete") }
            }.padding(14)
        } actions: {
            Button("Close") { store.sheet = nil }.keyboardShortcut(.cancelAction)
            Spacer()
            Text("No files changed · no automatic network").font(.caption).foregroundStyle(.secondary)
        }
        .task { path = request.path?.value ?? ""; from = request.expected.head ?? ""; to = request.commitOID ?? ""; token = UUID() }
        .task(id: token) {
            guard !path.isEmpty, !from.isEmpty else { return }
            busy = true; failure = nil
            do {
                let pair = try await request.repository.imageComparison(from: from, to: worktree ? nil : to, path: GitPath(path))
                let decoded = try await Task.detached { (try ImageThumbnail.make(pair.before), try ImageThumbnail.make(pair.after)) }.value
                try Task.checkCancellation(); before = decoded.0; after = decoded.1; busy = false; captured = true
                captureScope = from + " → " + (worktree ? "working file" : to) + " · " + path
            } catch is CancellationError {} catch { busy = false; failure = error.localizedDescription }
        }
        .onChange(of: path) { _, _ in captured = false }
        .onChange(of: from) { _, _ in captured = false }
        .onChange(of: to) { _, _ in captured = false }
        .onChange(of: worktree) { _, _ in captured = false }
    }
    private func picture(_ image: CGImage?, label: String) -> some View {
        VStack {
            Text(label + (image.map { " · \($0.width)×\($0.height) px" } ?? " · absent"))
                .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("imageDimensions:" + label)
            if let image {
                Image(image, scale: 1, label: Text(label + " image")).resizable().scaledToFit()
                    .accessibilityIdentifier("comparisonImage:" + label)
            }
            else { ContentUnavailableView("No image on this side", systemImage: "photo") }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
