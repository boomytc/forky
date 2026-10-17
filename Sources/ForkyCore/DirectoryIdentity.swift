import Foundation
import Darwin

/// Lookup identity is separate from the original URL presentation (/var vs /private/var).
public struct DirectoryIdentity: Hashable, Sendable {
    public let device: Int32
    public let inode: UInt64
    public static func read(_ url: URL) throws -> DirectoryIdentity? {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.utf8.contains(0) else { throw GitError.unsupportedPath }
        var info = stat()
        if stat(url.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw GitError.invalidInput("Cannot establish directory identity at " + url.path + ": " + String(cString: strerror(errno)))
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw GitError.invalidInput("Expected a directory at " + url.path) }
        return DirectoryIdentity(device: info.st_dev, inode: info.st_ino)
    }
}
