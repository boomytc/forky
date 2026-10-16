import Foundation
import Darwin

/// Intermediate directories and final files are never followed through symlinks.
enum SafeWorktree {
    struct Metadata { let isDirectory: Bool }
    static func metadata(at url: URL) throws -> Metadata? {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw failure(url.path)
        }
        guard info.st_mode & S_IFMT != S_IFLNK else { throw GitError.invalidInput("Refusing a symbolic link: " + url.path) }
        return Metadata(isDirectory: info.st_mode & S_IFMT == S_IFDIR)
    }
    static func failure(_ path: String) -> GitError { .invalidInput("File access failed at " + path + ": " + String(cString: strerror(errno))) }

    static func parent(root: URL, path: GitPath) throws -> (Int32, String) {
        var fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure(root.path) }
        let parts = path.value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { Darwin.close(fd); throw GitError.unsupportedPath }
        for part in parts.dropLast() {
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            Darwin.close(fd)
            guard next >= 0 else { throw failure(path.value) }
            fd = next
        }
        return (fd, parts.last!)
    }
    static func readFD(_ fd: Int32, limit: Int) throws -> Data {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0,
              info.st_size <= limit else { throw GitError.invalidInput("Only bounded regular files can be edited.") }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw failure("open file") }
            guard bytes.count <= limit - count else { throw GitError.outputLimit(limit) }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        return bytes
    }
    static func readAbsolute(_ url: URL, limit: Int) throws -> Data? {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 { if errno == ENOENT { return nil }; throw failure(url.path) }
        defer { Darwin.close(fd) }
        return try readFD(fd, limit: limit)
    }
    static func read(root: URL, path: GitPath, limit: Int) throws -> Data? {
        let (parent, name) = try parent(root: root, path: path)
        defer { Darwin.close(parent) }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 { if errno == ENOENT { return nil }; throw failure(path.value) }
        defer { Darwin.close(fd) }
        return try readFD(fd, limit: limit)
    }

    static func replace(root: URL, path: GitPath, data: Data?) throws {
        let (parent, name) = try parent(root: root, path: path)
        defer { Darwin.close(parent) }
        var info = stat()
        let exists = fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0
        guard exists || errno == ENOENT else { throw failure(path.value) }
        guard !exists || info.st_mode & S_IFMT == S_IFREG else { throw GitError.invalidInput("Conflict destination is not a regular file.") }
        guard let data else {
            if exists && unlinkat(parent, name, 0) != 0 { throw failure(path.value) }
            return
        }
        let temporary = ".forky-resolution-" + UUID().uuidString
        let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure(path.value) }
        defer { Darwin.close(fd) }
        do {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if written < 0 { if errno == EINTR { continue }; throw failure(path.value) }
                    guard written > 0 else { throw GitError.invalidInput("Incomplete conflict file write.") }
                    offset += written
                }
            }
            if exists {
                let source = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard source >= 0 else { throw failure(path.value) }
                defer { Darwin.close(source) }
                var current = stat()
                guard fstat(source, &current) == 0, current.st_ino == info.st_ino, current.st_dev == info.st_dev else { throw GitError.staleRepository }
                guard fcopyfile(source, fd, nil, copyfile_flags_t(COPYFILE_ACL | COPYFILE_XATTR)) == 0 else { throw failure(path.value) }
            }
            guard fchmod(fd, exists ? info.st_mode & 0o777 : 0o644) == 0, fsync(fd) == 0 else { throw failure(path.value) }
            guard renameat(parent, temporary, parent, name) == 0 else { throw failure(path.value) }
        } catch {
            let original = error
            if unlinkat(parent, temporary, 0) != 0 {
                throw GitError.invalidInput("Resolution staging-file cleanup failed; retained at " + root.appendingPathComponent(path.directory).appendingPathComponent(temporary).path + "\nOriginal failure: " + original.localizedDescription + "\nCleanup failure: " + failure(path.value).localizedDescription)
            }
            throw original
        }
    }
}

enum TemporaryInput {
    static func withFile<T: Sendable>(_ data: Data, body: @Sendable (URL) async throws -> T) async throws -> T {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Forky-input-" + UUID().uuidString)
        guard mkdir(directory.path, 0o700) == 0 else { throw SafeWorktree.failure(directory.path) }
        let file = directory.appendingPathComponent("input")
        let result: Result<T, any Error>
        do {
            try data.write(to: file, options: .withoutOverwriting)
            result = .success(try await body(file))
        } catch { result = .failure(error) }
        do { try FileManager.default.removeItem(at: directory) }
        catch {
            let earlier: String
            switch result { case .success: earlier = ""; case .failure(let failure): earlier = "\nOperation failure: " + failure.localizedDescription }
            throw GitError.invalidInput("Temporary input cleanup failed; retained at " + directory.path + earlier + "\n" + error.localizedDescription)
        }
        return try result.get()
    }
}
