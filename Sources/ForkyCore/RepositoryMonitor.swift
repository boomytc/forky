import Foundation
import CoreServices

private final class MonitorCallback: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    let handler: @Sendable () -> Void
    init(_ handler: @escaping @Sendable () -> Void) { self.handler = handler }
    func fire() {
        lock.lock(); let enabled = active; lock.unlock()
        if enabled { handler() }
    }
    func disable() { lock.lock(); active = false; lock.unlock() }
}

/// Recursive FSEvents observes worktree, per-worktree git dir and shared refs.
/// It never runs Git or network operations. stop is idempotent, including late callbacks.
public final class RepositoryMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private let callback: MonitorCallback
    public init(paths: [URL], onChange: @escaping @Sendable () -> Void) throws {
        callback = MonitorCallback(onChange)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(callback).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                let object = Unmanaged<MonitorCallback>.fromOpaque(pointer)
                _ = object.retain()
                return UnsafeRawPointer(pointer)
            }, release: { pointer in
                if let pointer { Unmanaged<MonitorCallback>.fromOpaque(pointer).release() }
            }, copyDescription: nil)
        guard let created = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            if let info { Unmanaged<MonitorCallback>.fromOpaque(info).takeUnretainedValue().fire() }
        }, &context, Array(Set(paths.map(\.path))) as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25,
        FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)) else {
            throw GitError.invalidInput("Filesystem monitoring could not be created. Manual refresh remains available.")
        }
        FSEventStreamSetDispatchQueue(created, DispatchQueue(label: "dev.forky.repository-events"))
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created); FSEventStreamRelease(created)
            throw GitError.invalidInput("Filesystem monitoring could not start. Manual refresh remains available.")
        }
        stream = created
    }
    public func stop() {
        callback.disable()
        lock.lock(); let old = stream; stream = nil; lock.unlock()
        if let old { FSEventStreamStop(old); FSEventStreamInvalidate(old); FSEventStreamRelease(old) }
    }
    deinit { stop() }
}
