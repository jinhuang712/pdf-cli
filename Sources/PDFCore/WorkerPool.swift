import Darwin
import Foundation

/// The worker slots that every parse on the Mac shares, so an agent reading many files at once
/// never runs more workers than the pool holds (DESIGNS.md → Decision: a shared pool of worker
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

    /// Takes a free slot, or returns nil when every slot this work may use is taken.
    ///
    /// Slot 0 is kept for work a command waits on, such as a page the agent asked for or a new
    /// file's index. Pages nobody asked for take only the other slots, so they never make a
    /// command wait. A pool of one slot has nothing to keep apart.
    public static func acquire(foreground: Bool, size: Int = Env.workerCount,
                               directory: URL = Env.cacheDirectory) -> Slot? {
        let folder = directory.appendingPathComponent("slots", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = foreground || size < 2 ? 0 : 1
        for number in first..<max(size, 1) {
            let path = folder.appendingPathComponent("slot-\(number).lock").path
            let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { continue }
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return Slot(number: number, descriptor: descriptor) }
            close(descriptor)
        }
        return nil
    }
}
