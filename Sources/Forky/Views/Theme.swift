import SwiftUI

enum ForkyTheme {
    static let accent = Color(nsColor: .controlAccentColor)
    static let brand = Color(red: 0.12, green: 0.60, blue: 0.43)
    static let panel = Color(nsColor: .controlBackgroundColor)
    static let subtle = Color(nsColor: .quaternaryLabelColor)
}

struct ForkyMark: View {
    var size: CGFloat = 42
    var body: some View {
        Image(systemName: "arrow.triangle.branch")
            .font(.system(size: size * 0.46, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(ForkyTheme.brand.gradient, in: .rect(cornerRadius: size * 0.25))
            .accessibilityLabel("Forky")
    }
}

struct EmptyPane: View {
    let icon: String
    let title: String
    let subtitle: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
