import Foundation

/// Parse text before URL(fileURLWithPath:) can silently expand it against cwd.
public enum LocalFilePath {
    public static func absolute(_ text: String) throws -> URL {
        guard text.hasPrefix("/"), !text.utf8.contains(0), text.utf8.count <= 65536 else {
            throw GitError.invalidInput("Use an absolute filesystem path. Relative paths, file URLs and shell tilde expansion are not used.")
        }
        return URL(fileURLWithPath: text)
    }
}
