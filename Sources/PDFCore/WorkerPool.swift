import Darwin
import Foundation

/// The worker slots that every parse on the Mac shares, so an agent reading many files at once
/// never runs more workers than the pool holds (plan/decisions/028-a-shared-pool-of-worker-slots-with-pages-nobody-waits-for-in-the.md → Decision: a shared pool of worker
/// slots, with pages nobody waits for at low priority).
///
/// A slot is an exclusive `flock` on a small file in the cache folder. The kernel drops the
/// lock when its holder exits, so a runner that crashes never keeps a slot.
public enum WorkerPool {
    /// A slot held until `release`, or until the slot is freed from memory.
    public final class Slot {
        public let number: Int
        private var descriptor: Int32

        init(number: Int, descriptor: Int32) {
            self.number = number
            self.descriptor = descriptor
        }

        public func release() {
            guard descriptor >= 0 else { return }
            close(descriptor)
            descriptor = -1
        }

        deinit { release() }
    }

    /// How long a command that failed to get a slot counts as still waiting for one.
    public static let waitingWindow: TimeInterval = 0.5

    static func waitingFile(_ directory: URL) -> URL {
        directory.appendingPathComponent("slots", isDirectory: true).appendingPathComponent("foreground-waiting")
    }

    /// Whether a command that waits on a page failed to get a slot a moment ago. Such a command
    /// polls every 20 ms, so the file's modification time is its heartbeat; a command that is
    /// gone leaves a mark that expires by itself.
    public static func foregroundWaiting(
        directory: URL = Env.cacheDirectory, window: TimeInterval = waitingWindow,
        now: Date = Date()
    ) -> Bool {
        let modified = (try? waitingFile(directory).resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        return modified.map { now.timeIntervalSince($0) < window } ?? false
    }

    static func noteForegroundWaiting(_ directory: URL) {
        let file = waitingFile(directory)
        if utimes(file.path, nil) != 0 {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
    }

    /// Takes a free slot, or returns nil when every slot this work may use is taken.
    ///
    /// Slot 0 is kept for work a command waits on, such as a page the agent asked for or a new
    /// file's index. Pages nobody asked for take only the other slots, so they never make a
    /// command wait. A pool of one slot (a light budget, or a Mac under pressure) has no other
    /// slot, so the pages nobody asked for share slot 0 and yield it: they take it only while no
    /// command is waiting for a slot, and a runner stops a background worker in it when one
    /// does (`Runner`), so a command never waits behind a parse that nobody waits for.
    public static func acquire(
        foreground: Bool, size: Int = Pressure.reduced(Env.workerCount),
        directory: URL = Env.cacheDirectory
    ) -> Slot? {
        let folder = directory.appendingPathComponent("slots", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if !foreground, size < 2, foregroundWaiting(directory: directory) { return nil }
        let first = foreground || size < 2 ? 0 : 1
        for number in first..<max(size, 1) {
            let path = folder.appendingPathComponent("slot-\(number).lock").path
            let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { continue }
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return Slot(number: number, descriptor: descriptor) }
            close(descriptor)
        }
        if foreground { noteForegroundWaiting(directory) }
        return nil
    }
}
